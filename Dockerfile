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
#   ROCM_VERSION     — ROCm version (e.g. 7.2.4)
#   UBUNTU_VERSION   — Ubuntu version (e.g. 24.04; informational)
#
# All ARG defaults are declared before any FROM. BuildKit does not
# consistently apply global-scope ARG defaults to a FROM declared
# later in the file, so all build-args live up here.

ARG UV_VERSION="0.12.5"
ARG PYTHON_VERSION="3.13"
ARG ROCM_VERSION="7.2.4"
ARG UBUNTU_VERSION="24.04"
ARG COMFYUI_VERSION

# Stage 1: pull the uv binary into a tiny side-image so we can COPY it
# into the main image without needing pip there.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# Stage 2: the real image. AMD's rocm/dev-ubuntu-24.04 ships:
#   - ROCm 7.2.4 runtime + dev tools at /opt/rocm
#   - An `ubuntu` user at UID/GID 1000 in the `video` group (matches
#     the nvidia/cuda base for parallel Dockerfile flow)
#   - No Python, no PyTorch — we install those into our own venv
#
# This is the closest analog to nvidia/cuda:13.0.3-cudnn-runtime-
# ubuntu24.04 in the cuda image. We layer on top: system packages,
# the entrypoint, our user rename, ComfyUI itself, and the venv.
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION}

# BuildKit's "global" ARG scope (above any FROM) only flows into FROM
# lines. Inside a stage, ARGs only persist if redeclared after the
# FROM. COMFYUI_VERSION is used in the git clone RUN below, so it
# must be re-declared here.
ARG COMFYUI_VERSION
ENV COMFYUI_HOME="/opt/comfyui"

# ROCm paths. The base image already has /opt/rocm/bin on PATH, but
# we re-declare explicitly so the Docker layer doesn't depend on
# AMD's choices. LD_LIBRARY_PATH is set in the running container by
# /etc/ld.so.conf.d/rocm*.conf from the base image — leaving it
# alone here.
ENV PATH="/opt/rocm/bin:/opt/rocm/llvm/bin:${PATH}"

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
        && uv cache clean \
    "

# Image size reduction. The rocm/dev-ubuntu-24.04 base ships
# toolchain material we don't need at inference time:
#
#   - /opt/rocm/lib/llvm          2.2 GB   LLVM/clang compiler
#   - /opt/rocm/bin/rocgdb-py_3.12 189 MB  ROCm debugger
#   - /opt/rocm/bin/rocgdb-py_3.13 191 MB  ROCm debugger
#   - /opt/rocm/bin/hipify-clang   57 MB   CUDA→HIP source translator
#   - /opt/rocm/bin/roccoremerge   6.4 MB  legacy kernel merger
#
# None of these are required for inference. Keep /opt/rocm/bin
# utilities (rocm-smi, amd-smi, rocminfo) and the runtime libs in
# /opt/rocm/lib (hsa, amdhip64, amd_comgr, etc.). Total savings:
# ~2.6 GB on disk, ~1.1 GiB compressed.
#
# Also strip --strip-unneeded on torch and triton shared objects.
# The PyPI wheels are built with most debug info already removed,
# but a small residue (~1 GB on torch, ~280 MB on triton) is left
# in. Stripping is safe — the wheels do not need debug symbols at
# runtime.
#
# Finally, prune the MIOpen kernel database to only the gfx targets
# we support. The torch wheel ships pre-compiled MIOpen databases
# for every supported gfx target (~780 MB total, ~50 files). For
# the targets this image supports (RDNA 4, RDNA 3, RDNA 3.5, MI300X,
# MI325X — i.e. gfx1200/1201, gfx1100/1101/1102, gfx1150/1151,
# gfx942, gfx950), only ~20 of those files are needed. The other
# ~30 are dead weight unless someone runs a gfx900/906/908/90a card.
# If a user does show up with one of those, MIOpen falls back to
# JIT compilation (slower first inference, then cached). Savings:
# ~390 MB on disk, ~150 MiB compressed.
#
# hadolint ignore=DL3003
RUN set -ex \
    # 1. Remove ROCm toolchain we don't need at runtime
    && rm -rf /opt/rocm/lib/llvm \
    && rm -f /opt/rocm/bin/rocgdb-py_3.12 /opt/rocm/bin/rocgdb-py_3.13 \
    && rm -f /opt/rocm/bin/hipify-clang /opt/rocm/bin/roccoremerge \
    # 2. Strip torch + triton shared objects
    && find /opt/comfyui/python/venv/lib/python3.13/site-packages/torch \
           -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true \
    && find /opt/comfyui/python/venv/lib/python3.13/site-packages/triton \
           -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true \
    # 3. Prune MIOpen db to supported gfx targets only
    && cd /opt/comfyui/python/venv/lib/python3.13/site-packages/torch/share/miopen/db \
    && find . -maxdepth 1 -type f \
           ! -name 'gfx942*' \
           ! -name 'gfx950*' \
           ! -name 'gfx1100*' \
           ! -name 'gfx1101*' \
           ! -name 'gfx1102*' \
           ! -name 'gfx1150*' \
           ! -name 'gfx1151*' \
           ! -name 'gfx1200*' \
           ! -name 'gfx1201*' \
           -delete \
    # 4. Also remove aotriton.images for gfx90a (older Instinct MI210/MI250)
    && rm -rf /opt/comfyui/python/venv/lib/python3.13/site-packages/torch/lib/aotriton.images/amd-gfx90a

EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8188/ || exit 1

ENTRYPOINT ["/opt/comfyui/entrypoint.sh"]
CMD ["--listen=0.0.0.0"]
