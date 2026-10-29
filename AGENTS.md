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
- `Dockerfile` — three stages: `uv` (side-image with the uv
  binary), `build` (the ROCm base + ComfyUI + venv + the gfx
  kernel prune), and `runtime` (plain `ubuntu:24.04` plus the
  pruned tree copied in, which is what makes the prune shrink the
  PULL size and not just the running container — see "Pruning needs
  a flattening stage" below). Takes `COMFYUI_VERSION` as a build
  arg, clones ComfyUI at that tag, installs Python deps via uv into
  a venv at `/opt/comfyui/python/venv` (inside the bind mount).
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
  +rocm7.14 wheels are pinned at the top, then the upstream ComfyUI
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

The test box for this project is a Ryzen 9 6900HX / Radeon 680M
host (gfx1035, RDNA 2 iGPU). It can build and smoke-test, but its
GPU is **not** one of the two supported architectures (gfx1201 /
gfx1100), so end-to-end GPU inference cannot be validated on it
for the current build — the entrypoint's gfx guard rejects it. Use
`GFX_ALLOWLIST=""` to bypass the guard when debugging, but the
per-architecture kernels for gfx1035 are pruned from the image, so
real inference will not work. End-to-end validation needs a gfx1201
(RDNA 4) or gfx1100 (RDNA 3) host.

Earlier revisions of this image (ROCm 7.2) also supported RDNA 3.5
iGPUs (gfx1150/1151/1152 — Strix Point, Strix Halo, Krackan
Point), including the `HSA_OVERRIDE_GFX_VERSION=11.5.1` workaround
needed by gfx1152 silicon. That support is gone in the current
build. See `docs/AMD-GPU-COMPATIBILITY.md`.

## Conventions

- Image tags: `<upstream-version>-rocm-<short>-<arch>`,
  e.g. `v0.34.0-rocm-7.14-amd64`.
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
- `ROCM_VERSION` (e.g. `7.14.1-full`) is the full base image tag of
  `rocm/dev-ubuntu-24.04`. ROCm 7.14+ is only published as
  `<version>-full` (the TheRock layout); the plain / `-complete`
  tags stopped after 7.2.x. The Dockerfile's `FROM` references the
  tag directly, and the requirements.txt's `--extra-index-url` is
  `rocm7.14` (the .X of the wheel index tracks the system ROCm, not
  the exact patch).
- `PYTHON_VERSION` (e.g. `3.13`) is the version of Python that `uv`
  installs into the venv. The rocm base ships no Python; `uv
  python install` fetches it.

## venv strategy: same as comfyui-cuda

This image is structurally identical to
[comfyui-cuda](https://github.com/genesis-scaffolding/comfyui-cuda)
now. Both:

- Use a thin GPU-runtime base (cuda: `nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04`
  / rocm: `rocm/dev-ubuntu-24.04:7.14.1-full`). Neither base ships
  Python or PyTorch.
- Install `uv` from a side-image, then have `uv` provision a
  Python interpreter into a venv at `/opt/comfyui/python/venv`.
- Install torch (cu130 / +rocm7.14 wheels) and ComfyUI into that
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
  [download.pytorch.org/whl/rocm7.14](https://download.pytorch.org/whl/rocm7.14/)
  wheels. Building torch is out of scope.

## GPU architecture policy: gfx1201 + gfx1100 only

This image supports exactly two AMD GPU architectures:

- `gfx1201` — RDNA 4 (R9700, AI PRO R9700, RX 9070 XT, RX 9070)
- `gfx1100` — RDNA 3 (RX 7900 XTX, RX 7900 XT, PRO W7900)

This is enforced, not just documented:

1. The build prunes every per-architecture kernel for other targets
   out of the ROCm base **and out of the torch wheel's bundled ROCm**
   (see "The wheel ships its own ROCm" below — the wheel's copy is
   what torch actually loads). The prune is a **generic sweep**, not
   a hand-written path list: every file or directory whose name
   contains a gfx arch token other than `gfx1100` / `gfx1201` is
   deleted. That covers hipBLASLt `library/gfx*`, rocBLAS Tensile
   kernels and per-arch dirs, hipSPARSELt, MIOpen's
   `libMIOpenCKGroupedConv_gfx*.so` (350 MB each), rocSHMEM device
   bitcode, MIOpen's kernel db, and the `.kpack` library blobs — a
   path list kept missing new ones.
   Measured: `/opt/rocm` goes from **19 GB / 47 gfx targets** in the
   base to **5.4 GB / 2 gfx targets** in the built image, and the
   wheel's `_rocm_sdk_libraries` from **12 GB** to **3 GB**.
2. `entrypoint.sh` detects the host GPU's gfx code via `rocminfo` at
   start-up and exits with an explicit error on anything else.
   Override with `GFX_ALLOWLIST=""`.
3. The build **asserts** that the prune actually took effect (it
   fails the build if any disallowed gfx token survives), so a
   silently-missed prune step cannot ship.

Consequences for development:

- The local test box's iGPU (Radeon 680M, gfx1035 — RDNA 2) is **not**
  a supported target, so end-to-end GPU testing of this build is not
  possible locally. The build-time checks (torch import, arch list,
  torchaudio import) still run on any host.
- Adding a third architecture means re-adding its tokens to the
  allowlist in the `Dockerfile` prune and to `GFX_ALLOWLIST` in
  `entrypoint.sh`.

Three ROCm-7.14-specific traps, all handled in the Dockerfile:

- The 7.14 base (TheRock layout) ships **no**
  `/etc/ld.so.conf.d/rocm*.conf`, so `LD_LIBRARY_PATH` must be set
  explicitly or `import torch` fails with
  "libamdhip64.so: cannot open shared object file".
- `/opt/rocm/lib/llvm` must **not** be deleted: `libMIOpen.so` and
  `libhipblaslt.so` link against `libLLVM.so` / `libclang-cpp.so`
  there. Only the LLVM headers/docs are pruned.
- **`find` does not follow a symlink given as the starting point.**
  In the TheRock layout `/opt/rocm/lib`, `/opt/rocm/bin` and
  `/opt/rocm/llvm` are symlinks into `/opt/rocm/core-7.14/` via
  `/etc/alternatives/`. So `find /opt/rocm/lib -maxdepth 1 -name
  '*.so'` matches **nothing**, exits 0, and looks like a successful
  prune while every file is still there. Always pass `-H`, and sweep
  from `/opt/rocm` (a real directory). An earlier revision of this
  Dockerfile shipped with exactly that bug: the image still carried
  4.4 GB of CDNA MIOpen kernels and every RDNA 3.5 iGPU kernel.

### Pruning needs a flattening stage to shrink the pull

Docker layers are additive: a file deleted in a later layer is
recorded as a whiteout, but its bytes stay in the layer that created
it. So the prune on its own shrinks the **running container's**
filesystem (`/opt/rocm`: 19 GB -> 5.4 GB) but does **not** reduce
the image's pull size — the 19 GB ROCm base layer is still
downloaded whole.

The `Dockerfile` therefore has three stages:

1. `uv` — a tiny side-image carrying the `uv` binary.
2. `build` — the ROCm base, ComfyUI, the venv, and the gfx prune.
3. `runtime` — plain `ubuntu:24.04` (78 MB) plus
   `COPY --from=build / /`, which re-materialises the **already
   pruned** tree into a fresh layer. The un-pruned base layers are
   never referenced by the published image, so they are never pulled.

Measured effect:

| | before | after |
|---|---|---|
| pull size (compressed) | 18.4 GB | **5.6 GB** |
| disk usage | 60.2 GB | **21.2 GB** |
| runtime filesystem | 25 GB | **15 GB** |

Consequences for development:

- The bake target pins `target = "runtime"`. Adding a stage to the
  Dockerfile means checking that the last stage is still the one we
  publish — `docker buildx bake --print` shows the resolved target.
- `COPY --from=build / /` does not carry over the base image's
  `ENV`, `WORKDIR`, `ENTRYPOINT` or `CMD`; the runtime stage
  re-declares them. Forgetting one is the likely failure mode here
  (a missing `PATH` or `LD_LIBRARY_PATH` breaks `import torch`).
- The base image's `USER`, `WORKDIR` and any `ENTRYPOINT` from
  `rocm/dev-ubuntu-24.04` are likewise not inherited. `COPY` does
  preserve file ownership, so the `comfyui` user and the `video`
  group survive.

### The wheel ships its own ROCm — prune it too

The torch ROCm wheel bundles a complete ROCm runtime of its own:

- `site-packages/_rocm_sdk_libraries` — 12 GB, the ROCm **runtime**
  (libamdhip64, libMIOpen, hipBLASLt, rocBLAS, RCCL, ...)
- `site-packages/_rocm_sdk_core` — 1.4 GB, the compiler and headers

`libtorch_hip.so` has `RPATH=$ORIGIN/../../_rocm_sdk_libraries/lib`,
so **the wheel's copy is what torch actually loads** — not the base
image's `/opt/rocm`. Pruning only `/opt/rocm` would leave every
unsupported target's kernels live in the runtime that matters. The
sweep therefore covers all four roots (`/opt/rocm`, site-packages,
`_rocm_sdk_core`, `_rocm_sdk_libraries`), and the build asserts that
all of them contain only gfx1100/gfx1201 afterwards.

site-packages is a root because the per-arch ROCm device packages
install their `dist-info` directories directly into it
(`rocm_sdk_device_gfx1012-7.14.1.dist-info` and friends). Leaving
those behind would claim packages are installed whose payload the
sweep just deleted — uv would see a half-installed environment.

### The `device-all` extra pulls every architecture

AMD ships the ROCm 7.14 runtime as one distribution **per
architecture** (`rocm-sdk-device-gfx1010` ... `gfx1201`, 25 of them).
The torch wheel declares:

```
Requires-Dist: rocm[device-all,libraries]==7.14.*
```

`device-all` expands to the device package for **every** supported
architecture — 25 packages, ~5.9 GB of downloads, 23 of them for
architectures this image can never run.

`overrides.txt` replaces that requirement with the `libraries` extra
only, and `requirements.in` then requests the two device packages we
actually need:

```
rocm-sdk-device-gfx1100==7.14.1
rocm-sdk-device-gfx1201==7.14.1
```

Measured effect on a fresh (bind-mounted) venv:

| | before | after |
|---|---|---|
| device packages downloaded | 25 (~5.9 GB) | 2 (~530 MB) |
| total download | ~8.1 GB | **~3.4 GB** |
| venv size on disk | ~18 GB | **~8.5 GB** |
| packages installed | 139 | 117 |

The override is applied in **both** places `uv pip install` runs —
the Dockerfile's build-time install and the entrypoint's runtime
refresh — otherwise the first container start on a machine whose
bind-mounted venv needs rebuilding would still pull the lot.

AMD's `rocm` package is an sdist that is rebuilt on the target
machine and inspects the local GPU to pick its target family. The
build host has no GPU and falls back to the default family while a
user's machine does not, so `ROCM_SDK_TARGET_FAMILY` is pinned in
the image to keep the two resolutions identical.

Two ROCm specifics the tokeniser has to handle:

- An arch code is not always 4 digits: `gfx90a` / `gfx90c` are 2
  digits + a letter, `gfx115x` is 3 digits + a letter.
- MIOpen's db has config files whose code carries a mixed
  digit/letter suffix: `gfx90878.HIP.fdb.txt`, `gfx90a68.db.txt`,
  `gfx90a6e.db.txt`. The token pattern takes the maximal digit run
  and then everything alphanumeric after it.

And the path match must be on **token boundaries**: the base image
contains a profiler directory literally named `gfx11`, and a naive
substring match would find `gfx11` inside `gfx1100` and delete the
kernel we need. The build also asserts the opposite failure mode —
that the sweep did NOT delete the gfx1100/gfx1201 kernels.
