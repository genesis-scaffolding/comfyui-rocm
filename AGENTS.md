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
  clones ComfyUI at that tag, installs Python deps via uv into a
  venv at `/opt/comfyui/python/venv` (inside the bind mount).
- `docker-bake.hcl` — bake config. Validates required variables and
  exposes the build target.
- `entrypoint.sh` — runs at container start. Handles UID/GID, syncs
  extensions from `extensions.sh`, refreshes the venv, starts
  ComfyUI. Bakes `--disable-pinned-memory` into the ComfyUI
  defaults (see the comment in the file for the rocm-specific
  reason).
- `extensions.sh` — list of pre-installed custom nodes (currently
  just ComfyUI-Manager). Add new extensions here.
- `requirements.in` — pinned Python dependencies. The torch
  +rocm7.2 wheels are pinned at the top, then the upstream ComfyUI
  requirements URL is templated on `COMFYUI_VERSION`.
- `metadata.env` — pinned versions of upstream tools (uv, ROCm,
  Python) and the default ComfyUI version used for local builds.
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
  the image for the local architecture and tags it
  `comfyui-rocm:test-v<comfyui>-rocm-<base>-amd64`. No GPU is
  required to build.
- **Smoke test (no GPU):** `docker run --rm
  comfyui-rocm:test-v<comfyui>-rocm-<base>-amd64 --help` exercises
  the entrypoint far enough to confirm Python and ComfyUI import.
  ROCm-using code paths are skipped because no GPU is available.
- **End-to-end test (needs an AMD GPU host):** on a machine with an
  R9700 / RX 9070 / MI300X / Ryzen AI iGPU and the AMD GPU driver
  installed, run
  `docker run --rm --device /dev/kfd --device /dev/dri --group-add video
  -p 8188:8188 comfyui-rocm:test-v<comfyui>-rocm-<base>-amd64` and
  verify ComfyUI serves at `http://localhost:8188`.

The test box for this project is a Ryzen AI 7 350 workstation
(Radeon 860M iGPU, gfx1152, RDNA 3.5). It can build, smoke-test,
AND run end-to-end tests because the rocm/dev-ubuntu-24.04 base has
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
- The build matrix is a single cell (`amd64`). The
  `rocm/dev-ubuntu-24.04` base is amd64-only, and ROCm has no
  stable arm64 support. If a user shows up with an Ampere Altra +
  AMD GPU, add a cell to the workflow.

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
- `ROCM_VERSION` (e.g. `7.2.4`) is the version tag of the
  `rocm/dev-ubuntu-24.04` base image. The Dockerfile's `FROM`
  references it directly, and the requirement.txt's
  `--extra-index-url` is `rocm7.2` (the .X of the wheel index
  tracks the system ROCm, not the exact patch).
- `PYTHON_VERSION` (e.g. `3.13`) is the version of Python that `uv`
  installs into the venv. The rocm base ships no Python; `uv
  python install` fetches it.

## venv strategy: same as comfyui-cuda

This image is structurally identical to
[comfyui-cuda](https://github.com/genesis-scaffolding/comfyui-cuda)
now. Both:

- Use a thin GPU-runtime base (cuda: `nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04`
  / rocm: `rocm/dev-ubuntu-24.04:7.2.4`). Neither base ships
  Python or PyTorch.
- Install `uv` from a side-image, then have `uv` provision a
  Python interpreter into a venv at `/opt/comfyui/python/venv`.
- Install torch (cu130 / +rocm7.2 wheels) and ComfyUI into that
  venv at build time.
- The venv path lives **inside the bind mount**
  (`./data/python:/opt/comfyui/python`), so user `pip install`s
  persist across `docker compose up --force-recreate`.

The previous revision of this repo used `rocm/pytorch:*` as the
base. That base ships a pre-built venv at `/opt/venv` *inside the
image*. That venv is wiped on every recreate, so user `pip
install`s were lost — a fundamental design bug. The cuda repo
never had this problem because its base has no venv. This repo
now matches the cuda repo.

## Performance gotcha: AOTriton env var

`TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` must be set in the
container environment, or PyTorch's `scaled_dot_product_attention`
falls back to the math backend (CPU) and ComfyUI hammers the CPU
at 100% while the GPU sits idle. With it, attention runs on the
GPU via AOTriton (~14x speedup on RDNA 3.5; similar on RDNA 4).
The `compose.yaml` sets this by default — do not remove it.
Same env var is needed for any PyTorch SDPA workload on AMD
ROCm, not just ComfyUI.

## Performance gotcha: --disable-pinned-memory

ComfyUI's default is to allocate a large host RAM staging buffer
(~15 GB) for fast H2D transfers. On a typical cuda workstation
(32 GB system, 16 GB VRAM) that fits; on an AMD workstation with
32 GB system + 32 GB VRAM (R9700), the pinned buffer plus OS plus
a 15 GB model load leaves almost no headroom and the system OOMs.
The entrypoint bakes `--disable-pinned-memory` into the ComfyUI
defaults, which costs a few % of H2D throughput but frees the
entire staging buffer. Disable via `COMFYUI_NO_DEFAULTS=true` and
pass your own flags if you have enough RAM for the default
behaviour.

## What we deliberately do not support

- NVIDIA / CUDA. Image only supports AMD GPUs with ROCm. Vulkan is
  also out of scope. The CUDA counterpart is
  [comfyui-cuda](https://github.com/genesis-scaffolding/comfyui-cuda).
- ARM64 hosts. The rocm base is amd64-only.
- Custom ComfyUI forks. We only build upstream ComfyUI tagged
  releases, not AMD's `rocm/comfyui` fork or any other fork.
- Windows / macOS hosts. Image is Linux-only.
- Building torch from source. We use PyTorch's official
  [download.pytorch.org/whl/rocm7.2](https://download.pytorch.org/whl/rocm7.2/)
  wheels. Building torch is out of scope.
