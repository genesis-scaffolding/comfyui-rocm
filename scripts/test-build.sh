#!/bin/bash
#
# Build the image locally for the current host architecture.
# Mimics one cell of the CI matrix so you can iterate without
# pushing commits.
#
# Usage: scripts/test-build.sh [comfyui_version]
#
#   comfyui_version   default: from metadata.env (COMFYUI_VERSION) —
#                      pass with the leading 'v' if you want a tag,
#                      e.g. scripts/test-build.sh v0.34.0
#
# Image is tagged as: comfyui-rocm:test-<comfyui>-rocm-<base>-amd64

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Source defaults from metadata.env (ignoring comments).
COMFYUI_VERSION="${1:-}"
if [ -z "${COMFYUI_VERSION}" ]; then
    COMFYUI_VERSION=$(grep '^COMFYUI_VERSION=' metadata.env | cut -d= -f2)
fi
UV_VERSION=$(grep '^UV_VERSION=' metadata.env | cut -d= -f2)
ROCM_BASE_TAG=$(grep '^ROCM_BASE_TAG=' metadata.env | cut -d= -f2)
[ -z "${UV_VERSION}" ] && UV_VERSION="0.12.5"

# Map current host arch to the matrix suffix.
case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *)
        echo "Unsupported host arch: $(uname -m)"
        echo "The rocm/pytorch base is linux/amd64 only. For cross-arch"
        echo "builds you'd need a different base; see the docs."
        exit 1
        ;;
esac

# COMFYUI_VERSION is the bare upstream version (e.g. 0.34.0) — the
# Dockerfile prepends 'v' where it needs the full tag (git clone,
# requirements URL template). Accept either form from the user and
# normalise to the bare form.
case "${COMFYUI_VERSION}" in
    v*) COMFYUI_VERSION="${COMFYUI_VERSION#v}" ;;
esac

# Short form of the ROCm base for the tag (e.g. rocm7.2.4 -> 7.2).
ROCM_SHORT=$(echo "${ROCM_BASE_TAG}" | sed -E 's/^rocm([0-9]+\.[0-9]+).*/\1/')

TAG="comfyui-rocm:test-v${COMFYUI_VERSION}-rocm-${ROCM_SHORT}-${ARCH}"

echo "=== comfyui-rocm local build ==="
echo "  ComfyUI:       v${COMFYUI_VERSION}"
echo "  ROCm base:     ${ROCM_BASE_TAG}"
echo "  uv:            ${UV_VERSION}"
echo "  Arch:          ${ARCH}"
echo "  Tag:           ${TAG}"
echo

# Use buildx with --load so the resulting image is available to the
# local docker daemon. This only works for the host's native platform.
docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg "COMFYUI_VERSION=${COMFYUI_VERSION}" \
    --build-arg "UV_VERSION=${UV_VERSION}" \
    --build-arg "ROCM_BASE_TAG=${ROCM_BASE_TAG}" \
    --tag "${TAG}" \
    --load \
    .

echo
echo "=== Build complete ==="
echo "Image: ${TAG}"
echo
echo "Smoke-test the entrypoint (no GPU required):"
echo "  docker run --rm ${TAG} --help   # starts ComfyUI, prints usage"
echo
echo "Confirm torch + ROCm combo (no GPU required):"
echo "  docker run --rm --entrypoint=/opt/venv/bin/python ${TAG} \\"
echo "      -c 'import torch; print(torch.__version__, torch.version.hip)'"
echo
echo "Run ComfyUI on a ROCm host (R9700, RX 9070, MI300X, ...):"
echo "  docker run --rm -it \\"
echo "    --device /dev/kfd --device /dev/dri --group-add video \\"
echo "    -p 8188:8188 \\"
echo "    ${TAG}"
