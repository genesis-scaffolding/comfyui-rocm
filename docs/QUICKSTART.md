# Quick Start

Get ComfyUI running in a Docker container on an AMD GPU in a few minutes.

## Prerequisites

1. A Linux host with an AMD GPU supported by ROCm 7.2.x. Confirmed targets:
   - **Radeon RX 9000 series (RDNA 4)** — e.g. R9700, RX 9070 XT (gfx1200/1201)
   - **Radeon RX 7000 series (RDNA 3)** — e.g. RX 7900 XTX, RX 7800 XT (gfx1100/1101)
   - **AMD Instinct MI300X / MI325X / MI355X** (gfx942/950)
2. Linux kernel 5.15+ (6.0+ recommended for gfx1201). The `amdgpu` driver
   ships in mainline, so most modern distros have it.
3. Docker installed.
4. ROCm userspace 6.4.4+ installed on the host. The kernel driver and
   the userspace are separate packages.
5. Your user in the `render` and `video` groups.

## Step 1 — install ROCm on the host

### Ubuntu 24.04 (recommended)

```bash
# Kernel driver usually comes with the distro; if not:
sudo apt install amdgpu-dkms

# ROCm userspace — pick one:
# Option A: distro package (older but simpler)
sudo apt install rocm
# Option B: AMD's installer script (latest, recommended for R9700)
sudo amdgpu-install --usecase=graphics,rocm

# Group access
sudo usermod -aG render,video $USER
newgrp render
newgrp video
```

### Other distros

See <https://rocm.docs.amd.com/en/latest/deploy/linux/quick_start.html> for
Arch, Fedora, RHEL, etc. The `amdgpu` kernel driver is upstream; only
the userspace (rocm runtime libraries) needs to be installed from AMD's
repo or your distro's repo.

## Step 2 — verify ROCm works

```bash
rocm-smi
# Expect: a table listing your AMD GPU(s) with driver version
```

```bash
python3 -c "import torch; print(torch.cuda.is_available())"
# Expect: True
```

If `torch.cuda.is_available()` returns False, your PyTorch install
isn't ROCm-enabled. On Ubuntu 24.04 with `sudo apt install rocm`,
this often means you need `python3-pip` and `pip install torch --index-url
https://download.pytorch.org/whl/rocm6.3` instead. The image's bundled
torch is irrelevant here — this is checking the **host** install.

## Step 3 — pick an image tag

Each release publishes one image per host architecture:

| Your host CPU | Image tag |
|---------------|-----------|
| `x86_64` / amd64 | `ghcr.io/genesis-scaffolding/comfyui-rocm:<version>-rocm-7.2-amd64` |

`<version>` is the upstream ComfyUI tag (e.g. `v0.34.0`), or use
`latest-rocm-7.2-amd64` for the rolling amd64 latest.

## Step 4 — pull

```bash
docker pull ghcr.io/genesis-scaffolding/comfyui-rocm:latest-rocm-7.2-amd64
```

## Step 5 — run

### One-liner

```bash
mkdir -p data
docker run --rm -it \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add video \
  -p 8188:8188 \
  -v "$PWD/data:/opt/comfyui/data" \
  ghcr.io/genesis-scaffolding/comfyui-rocm:latest-rocm-7.2-amd64
```

Open <http://localhost:8188>.

### `docker compose`

```bash
curl -SL -o compose.yaml \
  https://raw.githubusercontent.com/genesis-scaffolding/comfyui-rocm/main/compose.yaml
mkdir data
docker compose up -d
```

The compose file pins a specific tag for reproducibility. To follow
the latest, edit `compose.yaml` and change the `image:` line.

## Step 6 — install models

This image does **not** ship with models. You download them yourself
into the bind-mounted `./data/models/` directory, into the correct
subdirectory (ComfyUI's Manager tells you where each model goes).

Example layout:

```plain
data/models/
├── checkpoints/      # main SD checkpoints
├── loras/
├── vae/
├── controlnet/
└── ...
```

## Step 7 — install extensions

The image ships with [ComfyUI-Manager](https://github.com/ltdrdata/ComfyUI-Manager) pre-installed. Inside the ComfyUI UI, click **Manager → Install Custom Nodes** to add more. The installed custom nodes persist in `./data/custom_nodes/`.

## Verify ROCm is working in the container

```bash
docker exec -it <container> bash

# Inside the container:
rocm-smi
# Expect: GPU table with your host's GPUs

python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# Expect: True '<your GPU name>'
```

`torch.cuda.is_available()` is the canonical check on ROCm too — torch
exposes HIP devices through the CUDA API.

## Common operations

### Add custom CLI flags

Edit `command:` in `compose.yaml` (or pass extra args to `docker run`).
The image accepts any [ComfyUI server flag](https://docs.comfy.org/interface/settings/server-config), e.g. `--enable-flash-attention` or `--enable-sage-attention`.

To disable the image's default flags (`--listen=0.0.0.0`,
`--disable-auto-launch`), set `COMFYUI_NO_DEFAULTS=true` in the
container's environment.

### Match your host UID/GID

Set `PUID` and `PGID` in `compose.yaml` to match your host user. The
entrypoint chowns `/opt/comfyui` on first start.

### Use a specific GPU

`HIP_VISIBLE_DEVICES` is set to `0` by default (use the first GPU).
For multi-GPU hosts, set it to `0,1` (use both) or `1` (use the second
GPU only). The variable accepts a comma-separated list of GPU indices.

### Update the image

```bash
docker compose pull
docker compose up -d
```

## Troubleshooting

### `docker: Error response from daemon: error gathering device information while adding custom device "/dev/kfd"`

The `amdgpu` kernel driver is not loaded, or ROCm is not installed.
Check:
- `lsmod | grep amdgpu` — should list `amdgpu`
- `ls -l /dev/kfd` — should exist
- If `/dev/kfd` is missing, install the ROCm userspace (see Step 1).

### ComfyUI starts but no GPU detected inside the container

```bash
docker exec -it <container> rocm-smi
```

If `rocm-smi` works on the host but not in the container, the
`--device /dev/kfd --device /dev/dri --group-add video` flags are
missing or applied to the wrong service. The image's `compose.yaml`
has them; double-check your override.

### `torch.cuda.is_available()` is False inside the container

This is the same check as for a CUDA host — it's a torch question,
not a docker question. The bundled torch (`/opt/venv/bin/python -c
"import torch; print(torch.__version__, torch.version.hip)"`) should
report a `+rocm7.2.4` wheel. If it doesn't, the `rocm/pytorch` base
image's torch install is broken — file an issue.

### `Could not load the ROCm runtime library`

The `amdgpu` kernel driver is older than the ROCm userspace in the
container. Update both:
- `sudo apt update && sudo apt upgrade` (kernel + mesa + amdgpu)
- `sudo amdgpu-install --usecase=graphics,rocm` (latest ROCm)

### `unsupported gfx version: gfxXXXX`

Your GPU's gfx code is not in the bundled torch's compiled-in list.
The `rocm/pytorch:rocm7.2.4` base supports `gfx908;gfx90a;gfx1030;
gfx1100;gfx1101;gfx1150;gfx1151;gfx942;gfx1200;gfx1201` (verify
with `python -c "import torch; print(torch.cuda.get_arch_list())"`
inside the container). If your card isn't in that list, you need a
different base image — file an issue with the GPU model.

### ComfyUI starts but `http://localhost:8188` doesn't load

The container is listening on `0.0.0.0:8188` (verified in the entrypoint
defaults). If you can't reach it from the host, your host firewall or
docker network is blocking the port. Try `docker compose logs comfyui`
to see ComfyUI's bind address.

### Image won't pull

If the package is private, authenticate first:

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u $GITHUB_USER --password-stdin
```

## Next steps

- 📖 Read the [full README](../README.md)
- 🛠 Check [AMD GPU compatibility](AMD-GPU-COMPATIBILITY.md) for which GPUs are supported
- 🧰 See [REPOSITORY-STRUCTURE](REPOSITORY-STRUCTURE.md) for how to modify the build inputs
