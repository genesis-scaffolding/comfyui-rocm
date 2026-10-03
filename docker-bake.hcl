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

variable "PYTHON_VERSION" {
  default = "3.13"
}

# The rocm/dev-ubuntu-24.04:<ROCM_VERSION> tag encodes the ROCm
# version, the Ubuntu version, and the dev-tools layout. Currently
# the only Ubuntu version published is 24.04.
# See https://hub.docker.com/r/rocm/dev-ubuntu-24.04/tags for the
# full list of available ROCm versions.
variable "ROCM_VERSION" {
  default = "7.2.4"
}

variable "UBUNTU_VERSION" {
  default = "24.04"
}

target "build" {
  context = "."
  dockerfile = "Dockerfile"
  args = {
    "COMFYUI_VERSION" = COMFYUI_VERSION
    "UV_VERSION" = UV_VERSION
    "PYTHON_VERSION" = PYTHON_VERSION
    "ROCM_VERSION" = ROCM_VERSION
    "UBUNTU_VERSION" = UBUNTU_VERSION
  }
  # Default tag is overridden by the caller. Platform is overridden
  # per matrix cell (currently only amd64 — ROCm has no stable arm64).
  tags = ["${IMAGE}:unknown"]
  platforms = ["linux/amd64"]
}
