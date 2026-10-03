# AGENTS.md

This repo is a CI. It does not contain a ComfyUI checkout — it contains
the inputs that build a ComfyUI Docker image, plus the GitHub Actions
workflow that does the building.

## What this repo does

A scheduled GitHub Actions workflow:

1. Checks Comfy-Org/ComfyUI for the latest tagged release.
2. If it's a new tag (not already built here), runs a build matrix:
   one cell per (ROCm version × host architecture).
3. Each cell uses `docker buildx` to build the image, then pushes it
   to GHCR (`ghcr.io/genesis-scaffolding/comfyui-rocm`).
4. A release job creates a GitHub release with a body pointing at the
   published image tags.

The user-facing artifacts are the Docker images on GHCR and the
GitHub release entries. Everything else here is reproducible build
inputs.

## Repository layout

- `.github/workflows/build.yml` — the CI itself. Edit the matrix to
  add ROCm versions or host architectures.
- `Dockerfile` — multi-stage. Takes `COMFYUI_VERSION` as a build arg,
  clones ComfyUI at that tag, installs Python deps via uv into the
  base image's pre-existing `/opt/venv`.
- `docker-bake.hcl` — bake config. Validates required variables and
  exposes the build target.
- `entrypoint.sh` — runs at container start. Handles UID/GID, syncs
  extensions from `extensions.sh`, starts ComfyUI.
- `extensions.sh` — list of pre-installed custom nodes (currently
  just ComfyUI-Manager). Add new extensions here.
- `requirements.in` — pinned Python dependencies for extensions. The
  ComfyUI non-torch requirements are fetched from the upstream
  ComfyUI tag at the URL templated on `COMFYUI_VERSION`.
- `metadata.env` — pinned versions of upstream tools (uv, base ROCm
  image tag) and the default ComfyUI version used for local builds.
- `compose.yaml` / `compose.dev.yaml` — user-facing compose for
  running the image locally.
- `patches/` — local patches for extensions, applied at runtime by
  `patch_extension` in `entrypoint.sh`.
- `scripts/` — helper scripts for local builds and release checking.

## Testing contract

CI cannot verify ROCm behaviour (free runners have no AMD GPU). It
only verifies that the image builds and pushes. ROCm-specific
validation happens on the consumer's host at `docker run` time.

For local development:

- **Build verification (any host):** `scripts/test-build.sh` builds
  the image for the local architecture and tags it `comfyui-rocm:test`.
  No GPU is required to build.
- **Smoke test (no GPU):** `docker run --rm comfyui-rocm:test --help`
  exercises the entrypoint far enough to confirm Python and ComfyUI
  import. ROCm-using code paths are skipped because no GPU is
  available.
- **End-to-end test (needs an AMD GPU host):** on a machine with an
  R9700 / RX 9070 / MI300X / Ryzen AI iGPU and the AMD GPU driver
  installed, run
  `docker run --rm --device /dev/kfd --device /dev/dri --group-add video
  -p 8188:8188 comfyui-rocm:test` and verify ComfyUI serves at
  `http://localhost:8188`.

The test box for this project is a Ryzen AI 7 350 workstation
(Radeon 860M iGPU, gfx1152, RDNA 3.5). It can build, smoke-test,
AND run end-to-end tests because the rocm/pytorch base has
gfx1150/1151 in its kernel list and the iGPU's unified memory
works as VRAM. **For gfx1152 silicon (Krackan Point, e.g. Ryzen
AI 7 350), the container needs `HSA_OVERRIDE_GFX_VERSION=11.5.1`
or matmul segfaults.** See `docs/AMD-GPU-COMPATIBILITY.md` for
the workaround. The same device flags work for both the iGPU and
discrete AMD GPUs. Performance on the iGPU is bandwidth-limited
(no dedicated VRAM) but full ComfyUI inference runs successfully.

## Conventions

- Image tags: `<upstream-version>-rocm-<short>-<arch>`,
  e.g. `v0.34.0-rocm-7.2-amd64`.
- The `release` job uses the empty-commit-on-tag trick from
  comfyui-cuda: each GitHub Release points at a fresh empty commit
  so the release list sorts by build time.
- Workflow permissions default to `{}` at the top level; each job
  declares its own. The build job needs `packages: write`, the
  release job needs `contents: write`.
- The build matrix is a single cell (`amd64`). The rocm/pytorch base
  is amd64-only, and ROCm has no stable arm64 support. If a user
  shows up with an Ampere Altra + AMD GPU, add a cell to the
  workflow.

## Dockerfile ARG scope gotcha

BuildKit's "global-scope" `ARG` (declared before any `FROM`) only
flows into subsequent `FROM` lines. Inside a stage, `ARG`s only
persist if redeclared after the `FROM`. If an `ARG` is used in a
`RUN`, `COPY`, or `ENV` inside a stage, redeclare it immediately
after the stage's `FROM`. See `Dockerfile` for the pattern.

This is the same gotcha the comfyui-cuda repo's AGENTS.md calls out.

## Version conventions

- `COMFYUI_VERSION` is the **bare** upstream version (`0.34.0`),
  not the full tag (`v0.34.0`). The CI strips the `v` from
  upstream's `tag_name` before passing it. The Dockerfile prepends
  `v` where it needs the full tag (git clone branch, requirements
  URL template).
- `requirements.in` references `${COMFYUI_VERSION}`; the Dockerfile
  substitutes it via `sed` before `uv` reads the file. `uv` does
  not perform shell-style variable expansion on its input.
- `ROCM_BASE_TAG` is the full `rocm/pytorch` Docker Hub tag, e.g.
  `rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1`. It encodes
  the ROCm version, Ubuntu version, Python version, and PyTorch
  version. Bumping it is the only way to update the entire ROCm +
  Python + PyTorch stack. See <https://hub.docker.com/r/rocm/pytorch/tags>
  for the full list.

## Performance gotcha: AOTriton env var

`TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` must be set in the
container environment, or PyTorch's `scaled_dot_product_attention`
falls back to the math backend (CPU) and ComfyUI hammers the CPU
at 100% while the GPU sits idle. With it, attention runs on the
GPU via AOTriton (~14x speedup on RDNA 3.5; similar on RDNA 4).
The `compose.yaml` sets this by default — do not remove it.
Same env var is needed for any PyTorch SDPA workload on AMD
ROCm, not just ComfyUI.

## venv strategy (and how it differs from comfyui-cuda)

The CUDA repo's base (`nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04`)
ships without Python or PyTorch — so the CUDA repo's `entrypoint.sh`
creates a venv at `/opt/comfyui/python/venv` and installs torch into
it via the cu130 wheel index.

The ROCm repo's base (`rocm/pytorch:*`) already ships a pre-built
Python venv at `/opt/venv` with PyTorch matched to the ROCm runtime.
We use that venv directly:
- `entrypoint.sh` calls `uv pip install --python /opt/venv/bin/python
  -r requirements.in` to layer in additional deps (extension
  requirements, the comfyui_manager PyPI package). We do NOT
  reinstall torch.
- The venv is therefore not a per-container mount target. The
  `compose.yaml` still binds `./data/python:/opt/comfyui/python` so
  uv's package cache survives container recreations, but the
  actual Python interpreter comes from the base image.

This is the only material divergence from the cuda repo's design.

## What we deliberately do not support

- NVIDIA / CUDA. Image only supports AMD GPUs with ROCm. Vulkan is
  also out of scope. The CUDA counterpart is
  [comfyui-cuda](https://github.com/genesis-scaffolding/comfyui-cuda).
- ARM64 hosts. The rocm/pytorch base is amd64-only.
- Custom ComfyUI forks. We only build upstream ComfyUI tagged
  releases, not AMD's `rocm/comfyui` fork or any other fork.
- Windows / macOS hosts. Image is Linux-only.
- Building torch from source. We rely on the `rocm/pytorch` base to
  ship a validated multi-arch wheel. Going slimmer (e.g. starting
  from `rocm/rocm-terminal` and installing torch from
  `https://download.pytorch.org/whl/rocm6.3/`) is possible but out
  of scope for this repo; the resulting image would be smaller but
  we'd be on the hook for ROCm+PyTorch compat debugging.
