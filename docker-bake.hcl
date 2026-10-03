# Build target for use with `docker buildx bake`.
# Invoked by:
#   - CI: .github/workflows/build.yml (via docker/bake-action)
#   - Local: scripts/test-build.sh (via docker buildx build, which
#     reads the same args / build args)

# Variables below are populated by the caller (CI sets them via
# `set:` in docker/bake-action; local builds read from metadata.env).
# Defaults are intentionally empty for COMFYUI_VERSION so a missing
# value produces a clear error at build time (the URL substitution
# fails) rather than a confusing bake-time validation error.
variable "COMFYUI_VERSION" {
  default = ""
}

variable "IMAGE" {
  default = "ghcr.io/genesis-scaffolding/comfyui-rocm"
}

variable "UV_VERSION" {
  default = "0.12.5"
}

# The rocm/pytorch base tag encodes the ROCm version, Ubuntu version,
# Python version, and PyTorch version. E.g.
# rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1
# See https://hub.docker.com/r/rocm/pytorch/tags for the full list.
variable "ROCM_BASE_TAG" {
  default = "rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1"
}

target "build" {
  context = "."
  dockerfile = "Dockerfile"
  args = {
    "COMFYUI_VERSION" = COMFYUI_VERSION
    "UV_VERSION" = UV_VERSION
    "ROCM_BASE_TAG" = ROCM_BASE_TAG
  }
  # Default tag is overridden by the caller. Platform is overridden
  # per matrix cell (currently only amd64 — ROCm has no stable arm64).
  tags = ["${IMAGE}:unknown"]
  platforms = ["linux/amd64"]
}
