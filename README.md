# comfyui-rocm

Pre-built Docker images of [ComfyUI](https://github.com/Comfy-Org/ComfyUI) bundled with AMD ROCm runtime libraries, published automatically by a daily GitHub Actions CI.

> This repository does not run ComfyUI itself. It only contains the build inputs that produce the images. Pull the image from GHCR to actually use ComfyUI.

## Acknowledgement & inspiration

This project is the AMD ROCm counterpart to [**genesis-scaffolding/comfyui-cuda**](https://github.com/genesis-scaffolding/comfyui-cuda). The two repos share the same design: multi-stage `uv` binary, the same `entrypoint.sh` for UID/GID handling, the same pre-installed Manager extension, the same `requirements.in` for per-extension dependencies, the same CI shape (cron + `workflow_dispatch` → detect → build matrix → release with the empty-commit-on-tag trick), the same compose ergonomics, and the same AGENTS.md / docs/ layout. If you've used the cuda repo, this one will feel identical.

The base image — [`rocm/dev-ubuntu-24.04`](https://hub.docker.com/r/rocm/dev-ubuntu-24.04) — is published by AMD and provides a pre-validated Ubuntu 24.04 + ROCm runtime. This repo installs Python (via `uv`), PyTorch (from the official rocm7.14 wheel index), and ComfyUI on top. The venv lives at `/opt/comfyui/python/venv` inside the bind mount, so user `pip install`s persist across `docker compose up --force-recreate` — same persistence model as the cuda repo.

The earlier `corundex/ComfyUI-ROCm` (and the AMD-built [`rocm/comfyui`](https://hub.docker.com/r/rocm/comfyui)) image were also consulted for ROCm-specific device mapping conventions (`--device /dev/kfd --device /dev/dri --group-add video`) and compose env vars (`HIP_VISIBLE_DEVICES`, `CUDA_VISIBLE_DEVICES=""`). Thanks to the corundex and AMD authors for paving the way.

The earlier `corundex/ComfyUI-ROCm` (and the AMD-built [`rocm/comfyui`](https://hub.docker.com/r/rocm/comfyui)) image were also consulted for ROCm-specific device mapping conventions (`--device /dev/kfd --device /dev/dri --group-add video`) and compose env vars (`HIP_VISIBLE_DEVICES`, `CUDA_VISIBLE_DEVICES=""`). Thanks to the corundex and AMD authors for paving the way.

## Why this exists

Setting up ComfyUI on an AMD GPU is non-trivial: pick a ROCm version that supports your GPU, install PyTorch wheels for that ROCm, resolve ComfyUI's Python dependencies, optionally install custom nodes, configure UID/GID for bind-mount permissions, write a compose file. This repo handles the first three. The image is ready to run with a single `docker run`.

## Quick start

### One-liner

```bash
mkdir -p data
docker run --rm -it \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add video \
  -p 8188:8188 \
  -v "$PWD/data:/opt/comfyui/data" \
  ghcr.io/genesis-scaffolding/comfyui-rocm:latest-rocm-7.14-amd64
```

Open <http://localhost:8188> in a browser.

### docker compose

```bash
curl -SL -o compose.yaml https://raw.githubusercontent.com/genesis-scaffolding/comfyui-rocm/main/compose.yaml
mkdir -p data
docker compose up -d
# Open http://localhost:8188
```

The compose file uses a pinned image tag. To follow the latest build, edit `compose.yaml` and change the `image:` line to `ghcr.io/genesis-scaffolding/comfyui-rocm:latest-rocm-7.14-amd64`.

## Supported configurations

### Host CPU architecture

| Tag suffix | Platform | Typical hosts |
|------------|----------|---------------|
| `-amd64` | `linux/amd64` | Most desktops, servers, cloud VMs |

The rocm/dev-ubuntu-24.04 base is amd64-only. ROCm has no stable arm64 support, so this image does not publish an arm64 variant. Same constraint as the AMD-built `rocm/comfyui` image.

### ROCm / PyTorch version

| ROCm | Image tag suffix | PyTorch | Notes |
|------|------------------|---------|-------|
| 7.14.1 | `-rocm-7.14` | 2.14.1 | Current build. Base image is `rocm/dev-ubuntu-24.04:7.14.1-full` (TheRock layout). Supports **gfx1201** (RDNA 4) and **gfx1100** (RDNA 3) only — every other target is pruned from the image. |
| 7.2.4 | `-rocm-7.2` | 2.9.1 | Previous release. Supported gfx1201 (RDNA 4 / R9700), gfx1100/1101 (RDNA 3), RDNA 3.5 iGPUs (gfx1150/1151/1152 — Ryzen AI / Strix Point / Strix Halo / Krackan Point), and Instinct MI300X/MI325X/MI355X. |

The matrix starts with a single ROCm version. New versions are added to `.github/workflows/build.yml` (and `metadata.env`).

### Supported GPU architectures

This image ships GPU kernels for exactly two architectures:

| gfx code | Architecture | Example GPUs |
|----------|--------------|--------------|
| `gfx1201` | RDNA 4 | Radeon RX 9070 XT, RX 9070, R9700, Radeon AI PRO R9700 |
| `gfx1100` | RDNA 3 | Radeon RX 7900 XTX, RX 7900 XT, RX 7900 GRE, Radeon PRO W7900 |

Everything else (RDNA 2, RDNA 3 lower tier, RDNA 3.5 iGPUs, CDNA
datacenter parts) is **not supported**: the per-architecture kernels
are physically pruned from the image, and the entrypoint refuses to
start on an unsupported GPU with a clear message. Set
`GFX_ALLOWLIST=""` to bypass the check. See
[AMD GPU compatibility](docs/AMD-GPU-COMPATIBILITY.md).

### Image contents

- Base: `rocm/dev-ubuntu-24.04:7.14.1-full` (Ubuntu 24.04 + ROCm 7.14.1 runtime, TheRock layout)
- Python 3.13 in `/opt/comfyui/python/venv` (installed at build time via `uv`, with the venv inside the bind mount so `pip install`s persist)
- PyTorch 2.14.1 with ROCm 7.14 wheels from [download.pytorch.org](https://download.pytorch.org/whl/rocm7.14/) (kernels for gfx1201 and gfx1100)
- ComfyUI at the upstream tagged release
- [ComfyUI-Manager](https://github.com/ltdrdata/ComfyUI-Manager) (pre-installed as a custom node + the `comfyui_manager` PyPI backend package)
- `--disable-pinned-memory` baked into the ComfyUI defaults (saves ~15 GB of system RAM staging buffer; on a 32 GB system + 32 GB VRAM R9700, the default pinned buffer would OOM)
- Runs as unprivileged user `comfyui` (UID/GID configurable via `PUID`/`PGID`)

No additional custom nodes are pre-installed. Use ComfyUI-Manager inside the UI to install them.

### Image size

The published image is **~5.6 GB compressed** (~21 GB on disk). Two
things keep it there:

- **Per-arch kernel prune.** Every GPU architecture other than
  gfx1201/gfx1100 is physically deleted — from the ROCm base *and*
  from the ROCm runtime the torch wheel bundles (which is what torch
  actually loads). That is 45 of the 47 gfx targets the base image
  ships, and it takes `/opt/rocm` from 19 GB to 5.4 GB.
- **A flattening stage.** Docker layers are additive — a deleted file
  stays in the layer that created it, so pruning alone would not
  shrink the *pull*. The image is built in a `build` stage and then
  re-materialised into a plain `ubuntu:24.04` stage, so the
  un-pruned base layers are never pulled.

Without the prune and the flattening the same image is 18.4 GB
compressed / 60.2 GB on disk.

## Image naming

```
ghcr.io/genesis-scaffolding/comfyui-rocm:<upstream-version>-rocm-<short>-<arch>
```

Examples:
- `ghcr.io/genesis-scaffolding/comfyui-rocm:v0.43.0-rocm-7.14-amd64`
- `ghcr.io/genesis-scaffolding/comfyui-rocm:latest-rocm-7.14-amd64` — rolling latest, amd64 only

## Build process

A daily cron at 00:00 UTC and a manual `workflow_dispatch` trigger the build. On each run:

1. Query `Comfy-Org/ComfyUI` for the latest tagged release.
2. If the tag is new (not already present in this repo's git history), proceed; otherwise exit.
3. Build the image (one cell: amd64) using a native GitHub-hosted runner.
4. Push the image to GHCR.
5. Publish a GitHub Release with the image tags documented in the body.

See [`.github/workflows/build.yml`](.github/workflows/build.yml) for the full pipeline.

## Local development

Build and smoke-test on the current host:

```bash
# Build for the current architecture, tag as comfyui-rocm:test-v<comfyui>-rocm-<base>-amd64
./scripts/test-build.sh

# Smoke-test the entrypoint (no GPU required)
docker run --rm comfyui-rocm:test-v<comfyui>-rocm-<base>-amd64 --help   # starts ComfyUI, prints usage

# Confirm torch + ROCm combo (no GPU required)
docker run --rm --entrypoint=/opt/comfyui/python/venv/bin/python \
    comfyui-rocm:test-v<comfyui>-rocm-<base>-amd64 \
    -c 'import torch; print(torch.__version__, torch.version.hip)'
```

For end-to-end GPU validation, build on or copy the image to a host with an AMD GPU, then run with the device flags in the [Quick start](#quick-start) section. Free GitHub Actions runners do not provide AMD GPUs, so the CI can only verify that the image builds and pushes.

Check whether upstream has a newer release than the local checkout:

```bash
./scripts/check-releases.sh
```

## Adding custom nodes

1. Add the clone URL to `extensions.sh`:
   ```bash
   install_extension <slug> https://github.com/<owner>/<repo>.git
   ```
2. If the node has a `requirements.txt`, add a `-r` line under the
   node's slug in `requirements.in`.
3. Open a PR. The CI will rebuild the image once merged.

## APU / iGPU support (Ryzen AI, Strix, Krackan)

**Not supported in the current build.** The image ships kernels for
`gfx1201` and `gfx1100` only, so RDNA 3.5 iGPUs (`gfx1150`, `gfx1151`,
`gfx1152` — Strix Point, Strix Halo, Krackan Point) and RDNA 2 iGPUs
are pruned away. The 7.2-based image (previous release) did support
them; see the git history of this repo if you need an iGPU build.

The same `compose.yaml` and device flags work — the iGPU is just
another ROCm-visible device. Performance is bandwidth-limited (no
dedicated VRAM channel), so expect 5-15x slower than a discrete
RDNA 4 card of the same era, but full SD 1.5 / SDXL / Flux inference
is feasible on a Strix Halo or a 30 GB Krackan Point workstation.
See [AMD GPU compatibility](docs/AMD-GPU-COMPATIBILITY.md) for
specifics and gotchas.

## Links

- **ComfyUI upstream:** https://github.com/Comfy-Org/ComfyUI
- **ComfyUI CUDA counterpart:** https://github.com/genesis-scaffolding/comfyui-cuda
- **`rocm/dev-ubuntu-24.04` base:** https://hub.docker.com/r/rocm/dev-ubuntu-24.04
- **PyTorch ROCm wheels:** https://download.pytorch.org/whl/rocm7.14/
- **`rocm/comfyui` (inspiration, AMD-built):** https://hub.docker.com/r/rocm/comfyui
- **ComfyUI releases:** https://github.com/Comfy-Org/ComfyUI/releases
- **GHCR package:** https://github.com/orgs/genesis-scaffolding/packages/container/comfyui-rocm
- **AMD ROCm documentation:** https://rocm.docs.amd.com/

## Licence

MIT. See [LICENSE](LICENSE). Note that the resulting Docker images bundle third-party software under their own licences.

---

## Development credits

This project was designed and built with AI assistance. The division of work:

- **Concept, requirements, and architectural decisions**: Gen (the human owner of `genesis-scaffolding`).
- **Design proposals, implementation, debugging, and iteration**: an AI coding assistant.

The development was driven through the **[Pi](https://github.com/earendil-works/pi-coding-agent) agent harness**, with **Minimax-M3** as the primary model. The harness is the runtime that exposes tools (file reads/writes, shell execution, sub-agent delegation); the model is what proposes the actual edits.

If you fork or build on this repo, attribution to the upstream projects cited above and to the AI-assisted origin is appreciated but not legally required (the code is MIT).
