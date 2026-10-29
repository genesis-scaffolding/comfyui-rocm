# syntax=docker/dockerfile:1.7
#
# ComfyUI + ROCm runtime image.
#
# Mirrors comfyui-cuda/Dockerfile by design: thin base + we own the
# venv at /opt/comfyui/python/venv (inside the bind mount) so user
# `pip install`s persist across container recreates. The previous
# revision of this Dockerfile used rocm/pytorch as the base, which
# ships a pre-built venv at /opt/venv INSIDE THE IMAGE. That venv
# disappears with every `docker compose up --force-recreate`, so any
# `pip install` the user ran was lost. The cuda image has never had
# this problem because the cuda base has no venv — we create ours.
#
# Build args (set by docker-bake.hcl or the CLI):
#   COMFYUI_VERSION  — upstream tag (bare, e.g. 0.34.0)
#   UV_VERSION       — version of the uv binary to copy in
#   PYTHON_VERSION   — Python version for the venv (uv installs it;
#                      the rocm base has no Python)
#   ROCM_VERSION     — full base image tag (e.g. 7.14.1-full). ROCm
#                      7.14+ is only published as "<ver>-full"
#                      (TheRock layout); the plain/minimal tags
#                      stopped after 7.2.x.
#   UBUNTU_VERSION   — Ubuntu version (e.g. 24.04; informational)
#
# All ARG defaults are declared before any FROM. BuildKit does not
# consistently apply global-scope ARG defaults to a FROM declared
# later in the file, so all build-args live up here.

ARG UV_VERSION="0.12.5"
ARG PYTHON_VERSION="3.13"
ARG ROCM_VERSION="7.14.1-full"
ARG UBUNTU_VERSION="24.04"
ARG COMFYUI_VERSION

# Stage 1: pull the uv binary into a tiny side-image so we can COPY it
# into the main image without needing pip there.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# Stage 2: the real image. AMD's rocm/dev-ubuntu-24.04 ships:
#   - ROCm 7.14.1 runtime + dev tools at /opt/rocm
#   - An `ubuntu` user at UID/GID 1000 in the `video` group (matches
#     the nvidia/cuda base for parallel Dockerfile flow)
#   - No Python, no PyTorch — we install those into our own venv
#
# ROCm 7.14 is installed by AMD's TheRock scripts, which changes the
# layout compared to 7.2:
#   - /opt/rocm/{bin,lib,libexec,include,share,llvm,amdgcn} are
#     symlinks into /opt/rocm/core-7.14/ (via /etc/alternatives).
#     The real files live there, so pruning must target the
#     symlinked paths (they resolve fine).
#   - There is NO /etc/ld.so.conf.d/rocm*.conf any more, so
#     LD_LIBRARY_PATH must be set explicitly (see below) or the
#     torch wheel cannot find libamdhip64.so.
#   - The image is much bigger than 7.2.4 (~19 GB unpacked vs ~5 GB)
#     because it carries every ROCm component and every per-GPU-arch
#     kernel. We prune it hard further down (gfx1100 + gfx1201 only).
#
# This is the closest analog to nvidia/cuda:13.0.3-cudnn-runtime-
# ubuntu24.04 in the cuda image. We layer on top: system packages,
# the entrypoint, our user rename, ComfyUI itself, and the venv.
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION} AS build

# BuildKit's "global" ARG scope (above any FROM) only flows into FROM
# lines. Inside a stage, ARGs only persist if redeclared after the
# FROM. COMFYUI_VERSION is used in the git clone RUN below, so it
# must be re-declared here.
ARG COMFYUI_VERSION
ENV COMFYUI_HOME="/opt/comfyui"

# ROCm paths. The base image already has /opt/rocm/bin on PATH, but
# we re-declare explicitly so the Docker layer doesn't depend on
# AMD's choices.
#
# LD_LIBRARY_PATH: the ROCm 7.14 (TheRock) base image ships WITHOUT
# /etc/ld.so.conf.d/rocm*.conf, so nothing tells the dynamic loader
# where libamdhip64.so / libMIOpen.so / librocblas.so live. Without
# this, `import torch` fails with
# "libamdhip64.so: cannot open shared object file".
# /opt/rocm/lib is a symlink to /opt/rocm/core-7.14/lib.
ENV PATH="/opt/rocm/bin:/opt/rocm/llvm/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH}"

# Pin the ROCm meta-package's target family.
#
# AMD's `rocm` package is distributed as an sdist and is rebuilt from
# source on the target machine, where it inspects the local GPU to
# decide which architecture family it targets. The build host has no
# GPU (so it falls back to the default family) while a user's
# machine does, so the same requirements.in would resolve to
# different metadata on the two. Pinning it makes the build and the
# runtime resolution identical.
#
# The `device` extra is overridden away in overrides.txt, so this
# value does not decide which per-arch packages get installed — see
# requirements.in for the two that do.
ENV ROCM_SDK_TARGET_FAMILY=gfx1100

# OS-level packages needed by ComfyUI runtime + a few utilities used
# by the entrypoint and Manager. Same list as the cuda image.
#
# gcc + libc6-dev: required by Triton (PyTorch's JIT compiler) to
# compile GPU kernels at import time. Without these, the first model
# load that triggers a JIT-compile fails with "Failed to find C
# compiler". ~90 MB combined; much smaller than clang.
#
# The rocm base already ships libgl1, libnuma1, and rocm-dev. We do
# NOT need to install rocm.
#
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    set -ex \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates \
        curl \
        ffmpeg \
        gcc \
        git \
        gosu \
        libc6-dev \
        libglib2.0-0

# Rename the default `ubuntu` user to `comfyui`. The rocm/dev-ubuntu
# base ships an `ubuntu` user with UID/GID 1000, the same as the
# nvidia/cuda base. The entrypoint only has to handle UID/GID
# changes from here.
RUN set -ex \
    && groupmod -n comfyui ubuntu \
    && usermod -l comfyui -m -d "${COMFYUI_HOME}" ubuntu \
    && chown -R comfyui:comfyui "${COMFYUI_HOME}"

COPY --from=uv /uv /uvx /usr/local/bin/

WORKDIR ${COMFYUI_HOME}

# Copy the Python deps spec and the runtime scripts first so that
# changes to ComfyUI itself (cloned below) don't invalidate these
# cached layers.
COPY --chown=comfyui:comfyui ./requirements.in ./
COPY --chown=comfyui:comfyui ./overrides.txt ./
COPY --chown=comfyui:comfyui --chmod=0755 ./entrypoint.sh ./
COPY --chown=comfyui:comfyui --chmod=0644 ./extensions.sh ./
COPY --chown=comfyui:comfyui ./patches ./patches

# requirements.in references ${COMFYUI_VERSION} so we can pin the
# upstream ComfyUI requirements URL. uv reads the file verbatim, so
# the placeholder must be substituted before uv sees it. The entrypoint
# also re-runs `uv pip install` at container start, and benefits from
# this template being already filled in.
ARG COMFYUI_VERSION
RUN sed -i "s|\${COMFYUI_VERSION}|${COMFYUI_VERSION}|g" requirements.in

# Clone ComfyUI at the pinned version, then install Python deps as
# the comfyui user. The venv lives at /opt/comfyui/python/venv — a
# path INSIDE THE BIND MOUNT, so user `pip install`s done after the
# container is running persist across `docker compose up
# --force-recreate` (this is the bug the previous rocm/pytorch base
# design had; see the file header).
#
# COMFYUI_VERSION is the bare version (e.g. 0.34.0); the 'v' prefix
# is added here for git's tag format.
#
# hadolint ignore=DL3003
ARG COMFYUI_VERSION
ARG PYTHON_VERSION
RUN set -ex \
    && git clone --depth 1 --branch "v${COMFYUI_VERSION}" \
        https://github.com/Comfy-Org/ComfyUI.git app/ \
    && chown -R comfyui:comfyui . \
    && gosu comfyui bash -c "\
        export VIRTUAL_ENV='${COMFYUI_HOME}/python/venv' \
        && export UV_CACHE_DIR='${COMFYUI_HOME}/python/cache' \
        && uv python install '${PYTHON_VERSION}' \
        && uv venv --python '${PYTHON_VERSION}' --allow-existing \"\${VIRTUAL_ENV}\" \
        && uv pip install --compile-bytecode -r requirements.in \
             --overrides overrides.txt \
        && uv cache clean \
    "

# Smoke-check the install INSIDE the image. This catches the classic
# ROCm packaging break (torch wheel built for a different ROCm
# series, missing LD_LIBRARY_PATH, missing gfx kernels) at build
# time instead of at first user request.
#
# We assert:
#   1. torch imports and reports a HIP runtime,
#   2. torchaudio imports (ComfyUI's nodes_audio.py imports it at
#      module load, so a broken torchaudio breaks ComfyUI startup),
#   3. the wheel carries kernels for BOTH supported targets. The
#      wheel's own arch list also contains CDNA / RDNA 2 / RDNA 3.5
#      targets (it is one fat binary — those code objects cannot be
#      stripped from it), so we assert MEMBERSHIP, not exclusivity.
#      The runtime policy is enforced by the entrypoint's gfx guard
#      plus the per-arch kernel prune further down.
#
# hadolint ignore=DL3003
RUN set -ex \
    && gosu comfyui bash -c "\
        export VIRTUAL_ENV='${COMFYUI_HOME}/python/venv' \
        && \"\${VIRTUAL_ENV}/bin/python\" -c 'import torch, torchaudio; \
            archs = torch.cuda.get_arch_list(); \
            print(\"torch\", torch.__version__, \"hip\", torch.version.hip); \
            print(\"archs\", archs); \
            assert \"gfx1100\" in archs, \"wheel has no gfx1100 kernels\"; \
            assert \"gfx1201\" in archs, \"wheel has no gfx1201 kernels\"' \
    "

# Image size reduction + gfx-target restriction.
#
# This image supports exactly TWO GPU architectures:
#
#   gfx1201 — RDNA 4  (RX 9070 XT, RX 9070, R9700, AI PRO R9700)
#   gfx1100 — RDNA 3  (RX 7900 XTX, RX 7900 XT, RX 7900 GRE, PRO W7900)
#
# Everything else is out of scope and gets physically removed from
# the image (not just documented as unsupported):
#
#   gfx908/90a   — CDNA 1 (MI100/MI210/MI250)
#   gfx942/950   — CDNA 2 (MI300X/MI325X/MI355X)
#   gfx1250      — CDNA 4 (MI450)
#   gfx1030/31/32— RDNA 2 (RX 6000/5000)
#   gfx1101/1102 — RDNA 3 lower tier (RX 7800/7700/7600)
#   gfx1150..53  — RDNA 3.5 iGPUs (Ryzen AI / Strix / Krackan Point)
#   gfx1200      — RDNA 4 lower tier (RX 9060/9050)
#
# The ROCm 7.14.1-full base is ~19 GB unpacked, most of it per-arch
# kernels. We prune them down to the two supported targets.
#
# THE PRUNE IS A GENERIC SWEEP, NOT A PATH LIST.
#
# Rule: every file or directory under /opt/rocm whose name contains a
# gfx arch token other than gfx1100 / gfx1201 is deleted.
#
# A hand-written path list is exactly how the previous revision of
# this Dockerfile shipped an image that still carried 4.4 GB of CDNA
# MIOpen kernels, 296 MB of rocSHMEM bitcode and every RDNA 3.5 iGPU
# kernel: the `find` calls silently matched NOTHING (see the symlink
# trap below) and nothing failed loudly. The generic rule cannot miss
# a kernel set, including the ones that are easy to forget:
#
#   hipBLASLt     /opt/rocm/lib/hipblaslt/library/gfx<arch>/
#   rocBLAS       /opt/rocm/lib/rocblas/library/gfx<arch>/ + *.hsaco
#   hipSPARSELt   /opt/rocm/lib/hipsparselt/library/gfx<arch>/
#   MIOpen CK     /opt/rocm/lib/libMIOpenCKGroupedConv_gfx<arch>.so
#   rocSHMEM      /opt/rocm/lib/librocshmem_device_gfx<arch>.bc
#   library blobs /opt/rocm/core-7.14/.kpack/{blas,fft,rand,rccl}_lib_gfx<arch>.kpack
#   RCCL          kernels live in the .kpack blobs above
#
# SYMLINK TRAP (TheRock layout, ROCm 7.14+):
#
#   /opt/rocm/lib  -> /etc/alternatives/rocm-lib -> /opt/rocm/core-7.14/lib
#   /opt/rocm/bin  -> /etc/alternatives/rocm-bin -> /opt/rocm/core-7.14/bin
#   /opt/rocm/llvm -> /etc/alternatives/rocm-llvm -> /opt/rocm/core-7.14/llvm
#
# `find` does NOT follow a symlink given as the starting point unless
# you pass -H. So `find /opt/rocm/lib -maxdepth 1 -name '*.so'` matches
# NOTHING at all and still exits 0 — a silent no-op that looks like a
# successful prune. Always pass -H, and sweep from /opt/rocm (a real
# directory) so the whole core-7.14 tree is covered.
#
# NOTE: /opt/rocm/lib/llvm MUST NOT be removed. libMIOpen.so and
# libhipblaslt.so link against libLLVM.so / libclang-cpp.so there.
# /opt/rocm/llvm (the clang/hipcc toolchain) is kept as well —
# Triton needs it to JIT-compile HIP kernels.
#
# Also strip --strip-unneeded on torch and triton shared objects.
# The PyPI wheels are built with most debug info already removed,
# but a small residue (~1 GB on torch, ~280 MB on triton) is left
# in. Stripping is safe — the wheels do not need debug symbols at
# runtime.
#
# hadolint ignore=DL3003
RUN set -ex \
    # 1. Toolchain / profiling / debugging we never use at inference
    #    time. NOTE: the real rocprofiler-compute payload lives under
    #    libexec/, not lib/ — the old rm list missed it.
    && rm -rf /opt/rocm/lib/rdc /opt/rocm/lib/rocprofiler-sdk \
              /opt/rocm/lib/rocprofiler-systems /opt/rocm/lib/roctracer \
              /opt/rocm/lib/rocprofiler-compute \
              /opt/rocm/libexec/rocprofiler-compute \
              /opt/rocm/libexec/rocprofiler-sdk \
              /opt/rocm/libexec/roctracer \
              /opt/rocm/share/rdc /opt/rocm/share/rocgdb \
              /opt/rocm/share/rocprofiler-sdk /opt/rocm/share/rocprofiler-systems \
              /opt/rocm/share/roctracer /opt/rocm/share/doc \
    && rm -rf /opt/rocm/lib/python3.10 /opt/rocm/lib/python3.11 \
              /opt/rocm/lib/python3.12 /opt/rocm/lib/python3.13 \
    && rm -f /opt/rocm/bin/rocgdb-py_3.10 /opt/rocm/bin/rocgdb-py_3.11 \
          /opt/rocm/bin/rocgdb-py_3.12 /opt/rocm/bin/rocgdb-py_3.13 \
          /opt/rocm/bin/hipify-clang /opt/rocm/bin/roccoremerge \
    # 2. LLVM headers/docs (keep bin+lib: triton/hipcc need the
    #    compiler, MIOpen + hipBLASLt need libLLVM.so)
    && rm -rf /opt/rocm/llvm/include /opt/rocm/llvm/share \
    # 3. Compile-time-only device libraries (hipcc device linking)
    && rm -f /opt/rocm/lib/libdevice_*.a \
    # 4. MIOpen's system-wide kernel database. It only carries CDNA +
    #    RDNA 2 entries; gfx1100/gfx1201 always used MIOpen's built-in
    #    fallback / JIT path.
    && rm -rf /opt/rocm/share/miopen/db \
    # 5. THE PRUNE. Generic sweep of every per-arch artifact for a
    #    target we do not support. See the comment block above.
    #
    #    Three roots are swept, and ALL THREE MATTER:
    #
    #      /opt/rocm                     the ROCm base image's runtime
    #      .../_rocm_sdk_core            the torch wheel's bundled
    #                                   ROCm SDK (compiler + headers)
    #      .../_rocm_sdk_libraries       the torch wheel's bundled ROCm
    #                                   RUNTIME — and this is the one
    #                                   torch actually loads. torch's
    #                                   libtorch_hip.so has
    #                                   RPATH=$ORIGIN/../../_rocm_sdk_
    #                                   libraries/lib, so the base
    #                                   image's /opt/rocm is NOT what
    #                                   torch links against. Pruning
    #                                   only /opt/rocm would leave
    #                                   every unsupported target's
    #                                   kernels live in the runtime
    #                                   that matters.
    #
    #    site-packages itself is a root too, because the per-arch
    #    ROCm device packages install their dist-info directories
    #    directly into it (rocm_sdk_device_gfx1012-7.14.1.dist-info
    #    and friends). Leaving those behind would claim packages are
    #    installed whose payload the sweep just deleted.
    #
    #    Tokenising matters, twice over:
    #
    #    1. A gfx arch code is NOT always 4 digits: gfx90a / gfx90c are
    #       2 digits + a letter, gfx115x is 3 digits + a letter,
    #       gfx1100 is 4 digits — and MIOpen's db has config files
    #       like "gfx90878.HIP.fdb.txt", "gfx90a68.db.txt" and
    #       "gfx90a6e.db.txt" where the code carries a mixed
    #       digit/letter suffix. So the pattern takes the maximal
    #       digit run (2 or more) and then everything alphanumeric
    #       that follows it.
    #    2. The path match must be on TOKEN BOUNDARIES, not on raw
    #       substrings. The base image contains a profiler directory
    #       literally named "gfx11" — a naive substring match would
    #       find "gfx11" inside "gfx1100" and delete the very kernel
    #       we need. Hence the [^0-9A-Za-z] guards on both sides.
    #
    #    GNU grep is used rather than awk on purpose: mawk's regex
    #    engine is not leftmost-longest for consecutive optionals and
    #    happily turns "gfx1100" into the token "gfx110".
    && gfx_roots="/opt/rocm \
                  /opt/comfyui/python/venv/lib/python3.13/site-packages \
                  /opt/comfyui/python/venv/lib/python3.13/site-packages/_rocm_sdk_core \
                  /opt/comfyui/python/venv/lib/python3.13/site-packages/_rocm_sdk_libraries" \
    && gfx_tokens="$(for r in ${gfx_roots}; do \
                       find -H "$r" -name '*gfx*' -printf '%f\n' 2>/dev/null; \
                   done | grep -oE 'gfx[0-9]{2,}[a-z0-9]*' | sort -u)" \
    && gfx_drop="$(printf '%s\n' "${gfx_tokens}" \
                  | grep -vxE 'gfx1100|gfx1201' | paste -sd'|')" \
    && if [ -n "${gfx_drop}" ]; then \
           for r in ${gfx_roots}; do \
               if [ -d "$r" ]; then \
                   find -H "$r" -name '*gfx*' -printf '%p\n' 2>/dev/null \
                     | grep -E "(^|[^0-9A-Za-z])(${gfx_drop})([^0-9A-Za-z]|\$)" \
                     | tr '\n' '\0' | xargs -0 -r rm -rf; \
               fi; \
           done; \
       fi \
    # 6. ASSERT the prune actually took effect, for every root.
    #    Without this, a silently-missed prune step ships unnoticed
    #    and the only symptom is a multi-GB fatter image.
    && gfx_left="$(for r in ${gfx_roots}; do \
                       find -H "$r" -name '*gfx*' -printf '%f\n' 2>/dev/null; \
                   done | grep -oE 'gfx[0-9]{2,}[a-z0-9]*' | sort -u \
                 | grep -vxE 'gfx1100|gfx1201' || true)" \
    && if [ -n "${gfx_left}" ]; then \
           echo "ERROR: unsupported GPU arch kernels survived the prune:" >&2; \
           echo "${gfx_left}" >&2; \
           exit 1; \
       fi \
    # 6b. ASSERT the sweep did not over-prune. The tokeniser has to
    #     tell "gfx1100" from "gfx11"; if it ever gets that wrong the
    #     supported kernels are deleted and the image breaks at
    #     inference time, long after the build. Fail here instead.
    && gfx_kept="$(for r in ${gfx_roots}; do \
                       find -H "$r" -name '*gfx*' -printf '%f\n' 2>/dev/null; \
                   done | grep -oE 'gfx[0-9]{2,}[a-z0-9]*' | sort -u)" \
    && for want in gfx1100 gfx1201; do \
           if ! printf '%s\n' "${gfx_kept}" | grep -qx "${want}"; then \
               echo "ERROR: the sweep deleted the ${want} kernels" >&2; \
               exit 1; \
           fi; \
       done \
    # 7. Strip torch + triton shared objects
    && find /opt/comfyui/python/venv/lib/python3.13/site-packages/torch \
           -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true \
    && find /opt/comfyui/python/venv/lib/python3.13/site-packages/triton \
           -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 3: flatten.
#
# Docker layers are additive. Every byte the gfx sweep deleted is still
# present in the layer that created it (as a whiteout), so the prune
# reduces the RUNNING CONTAINER's footprint but NOT the image's pull
# size — the 19 GB ROCm base layer is still downloaded whole.
#
# This stage is the only way to make the deletions count. The final
# image re-materialises the already-pruned filesystem into a fresh
# layer, so the un-pruned base layers are never referenced by the
# image we publish and never get pulled.
#
# Measured effect on this image:
#
#   pull size (compressed)   18.4 GB  ->  5.6 GB
#   disk usage               60.2 GB  ->  21.2 GB
#
# The base here is plain ubuntu:24.04 (78 MB) — everything else is
# copied in from the build stage, which is the pruned tree.
# ---------------------------------------------------------------------------
ARG UBUNTU_VERSION
FROM ubuntu:${UBUNTU_VERSION} AS runtime

COPY --from=build / /

# The base image's ENV/WORKDIR/ENTRYPOINT do not carry over to a new
# FROM, so they are re-declared here.
ENV COMFYUI_HOME="/opt/comfyui"
ENV PATH="/opt/rocm/bin:/opt/rocm/llvm/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH}"
ENV ROCM_SDK_TARGET_FAMILY=gfx1100

WORKDIR ${COMFYUI_HOME}

EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8188/ || exit 1

ENTRYPOINT ["/opt/comfyui/entrypoint.sh"]
CMD ["--listen=0.0.0.0"]
