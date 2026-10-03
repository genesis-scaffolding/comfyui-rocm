# syntax=docker/dockerfile:1.7
#
# ComfyUI + ROCm runtime image.
#
# Build args (set by docker-bake.hcl or the CLI):
#   COMFYUI_VERSION  — upstream tag (bare, e.g. 0.34.0; the Dockerfile
#                      prepends 'v' where the full tag is needed)
#   UV_VERSION       — version of the uv binary to copy in
#   ROCM_BASE_TAG    — tag of the rocm/pytorch image to FROM. Encodes
#                      the ROCm version, Ubuntu version, Python version,
#                      and PyTorch version (e.g.
#                      rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1).
#                      The base image ships /opt/venv with torch+rocm
#                      matched and validated, so we don't reinstall torch.
#
# All ARG defaults are declared before any FROM. BuildKit does not
# consistently apply global-scope ARG defaults to a FROM declared
# later in the file, so all build-args live up here.

ARG UV_VERSION="0.12.5"
ARG ROCM_BASE_TAG="rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1"
ARG COMFYUI_VERSION

# Stage 1: pull the uv binary into a tiny side-image so we can COPY it
# into the main image without needing pip there.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# Stage 2: the real image. AMD's official rocm/pytorch base ships:
#   - ROCm runtime + userspace at /opt/rocm
#   - A pre-built Python venv at /opt/venv with PyTorch matched to
#     the ROCm version (multi-arch wheels, includes gfx1201 for
#     RDNA 4 / R9700)
#   - The /opt/venv/bin path is already on PATH
# We layer on top: the entrypoint, our user, ComfyUI itself, and any
# extension requirements. We do NOT reinstall torch.
FROM rocm/pytorch:${ROCM_BASE_TAG}

# BuildKit's "global" ARG scope (above any FROM) only flows into FROM
# lines. Inside a stage, ARGs only persist if redeclared after the
# FROM. COMFYUI_VERSION is used in the requirements.in sed and the
# git clone below, so it must be re-declared here.
ARG COMFYUI_VERSION
ENV COMFYUI_HOME="/opt/comfyui"

# OS-level packages needed by ComfyUI runtime + the entrypoint. The
# rocm/pytorch base already has most of what we need; this layer only
# adds the small set it doesn't ship.
#
# gcc + libc6-dev: required by Triton (PyTorch's JIT compiler, also
# used by comfy-aimdo and several other backends) to compile GPU
# kernels at import time. Without these, the first model load that
# triggers a JIT-compile fails with "Failed to find C compiler".
# ~90 MB combined; much smaller than clang.
#
# gosu: UID/GID drop in entrypoint.sh.
#
# curl: HEALTHCHECK command.
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
        libgl1 \
        libglib2.0-0

COPY --from=uv /uv /uvx /usr/local/bin/

# Rename the default `ubuntu` user (UID/GID 1000) to `comfyui` and
# set the home directory to ${COMFYUI_HOME}. The rocm/pytorch base
# ships an `ubuntu` user with UID/GID 1000, the same as the
# nvidia/cuda base. The entrypoint only has to handle UID/GID
# changes from here.
#
# /opt/venv in the base is root-owned. We need comfyui to be able
# to write there at build time (for the `uv pip install` below) and
# at runtime (the entrypoint runs `uv pip install -r requirements.in`
# on every container start to layer in extension deps).
#
# IMPORTANT: do NOT `chown -R` the venv. Docker's overlay driver
# copies file data into the new layer when an existing file's
# owner changes — so `chown -R` on a 4.8 GB venv produces a 4.8 GB
# layer. chown the *directory entries* (no -R) so the dir inodes
# are owned by comfyui but the existing files stay on the base
# layer. New files created under those dirs at build/runtime are
# owned by comfyui, which is what we need.
RUN set -ex \
    && groupmod -n comfyui ubuntu \
    && usermod -l comfyui -m -d "${COMFYUI_HOME}" ubuntu \
    && chown -R comfyui:comfyui "${COMFYUI_HOME}" \
    && chown comfyui:comfyui \
        /opt/venv \
        /opt/venv/bin \
        /opt/venv/lib \
        /opt/venv/lib/python3.12 \
        /opt/venv/lib/python3.12/site-packages

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
# the placeholder must be substituted before uv sees it.
ARG COMFYUI_VERSION
RUN sed -i "s|\${COMFYUI_VERSION}|${COMFYUI_VERSION}|g" requirements.in

# Clone ComfyUI at the pinned upstream tag, then install Python deps
# into the base's /opt/venv (which already has torch+rocm pre-validated
# for this ROCm version — we don't reinstall it). The entrypoint
# re-runs `uv pip install` at container start, and benefits from
# this template being already filled in.
#
# COMFYUI_VERSION is the bare version (e.g. 0.34.0); the 'v' prefix
# is added here for git's tag format.
#
# hadolint ignore=DL3003
ARG COMFYUI_VERSION
RUN set -ex \
    && git clone --depth 1 --branch "v${COMFYUI_VERSION}" \
        https://github.com/Comfy-Org/ComfyUI.git app/ \
    && chown -R comfyui:comfyui . \
    && gosu comfyui bash -c "\
        uv pip install --python /opt/venv/bin/python --compile-bytecode \
            -r ${COMFYUI_HOME}/requirements.in && \
        uv cache clean \
    "

EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8188/ || exit 1

ENTRYPOINT ["/opt/comfyui/entrypoint.sh"]
CMD ["--listen=0.0.0.0"]
