# AMD GPU & ROCm Compatibility

This image targets AMD GPUs supported by ROCm 7.2.4 with PyTorch 2.9.1
multi-arch wheels. The base image is
[`rocm/pytorch:rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1`](https://hub.docker.com/r/rocm/pytorch/tags);
its built-in torch supports the gfx targets listed below.

## Finding your GPU's gfx code

```bash
# On the host, with the amdgpu driver loaded:
rocminfo | grep -A1 "Name:"
# Or:
python3 -c "import torch; print(torch.cuda.get_device_capability())"
```

The gfx code is what determines ROCm compatibility. For example:

| GPU | gfx code | Family |
|-----|----------|--------|
| R9700 (workstation) | gfx1201 | RDNA 4 |
| RX 9070 XT | gfx1200 | RDNA 4 |
| RX 9070 | gfx1200 | RDNA 4 |
| RX 7900 XTX | gfx1100 | RDNA 3 |
| RX 7800 XT | gfx1101 | RDNA 3 |
| RX 7700 XT | gfx1101 | RDNA 3 |
| RX 7600 | gfx1102 | RDNA 3 |
| RX 6950 XT | gfx1030 | RDNA 2 |
| RX 6800 XT | gfx1030 | RDNA 2 |
| MI300X | gfx942 | CDNA 2 |
| MI325X | gfx950 | CDNA 2 |
| MI355X | gfx950 | CDNA 2 |

## Supported GPUs (image built on ROCm 7.2.4)

| Family | Example GPUs | Min ROCm | Notes |
|--------|--------------|----------|-------|
| **RDNA 4 (gfx1200/1201)** | R9700, RX 9070 XT, RX 9070 | 6.3+ | **32GB workstation variants (R9700) supported.** Best consumer targets as of late 2025. |
| **RDNA 3.5 iGPU (gfx1150/1151/1152)** | Ryzen AI 9 HX 370, Ryzen AI Max 395, Ryzen AI 7 350 (Radeon 860M) | 6.4+ | **Unified memory: VRAM drawn from system RAM.** Krackan Point / Strix Point / Strix Halo. Tested with Radeon 860M. See [APU section](#apu--ryzen-ai-igpu-section) below. |
| **RDNA 3 (gfx1100/1101/1102)** | RX 7900 XTX, RX 7800 XT, RX 7700 XT, RX 7600 | 5.7+ | First ROCm-friendly consumer RDNA generation. |
| **RDNA 2 (gfx1030/1031/1032)** | RX 6950 XT, RX 6800 XT, RX 6700 XT, RX 6600 | 5.0+ | ROCm 5.x onward; some quirks on the lower-tier cards. |
| **CDNA 2 (gfx942/950)** | Instinct MI300X, MI325X, MI355X | 6.0+ | Datacenter. The official `rocm/comfyui` image targets only these. |
| **CDNA (gfx908/90a)** | Instinct MI100, MI210, MI250 | 5.0+ | Older datacenter. Still works with this image. |

This is a representative subset. The full list is the `PYTORCH_ROCM_ARCH`
the base image was built with — verify inside the container with:

```bash
docker exec -it <container> \
    /opt/venv/bin/python -c "import torch; print(torch.cuda.get_arch_list())"
```

Expected output (for the 7.2.4 base): `gfx908`, `gfx90a`, `gfx942`,
`gfx950`, `gfx1030`, `gfx1100`, `gfx1101`, `gfx1102`, `gfx1150`,
`gfx1151`, `gfx1200`, `gfx1201` (exact list may vary slightly per
release).

## APU / Ryzen AI iGPU section

APU integrated GPUs are a special case: there's no dedicated VRAM,
the iGPU draws from system RAM via the unified-memory architecture.
This changes both the effective VRAM available and the performance
characteristics.

### How it works

The Linux `amdgpu` kernel driver exposes the APU's iGPU to ROCm
through the same KFD interface as discrete GPUs. Once the iGPU is
in a usable power state, the rocm/pytorch base image's pre-built
torch detects it as a HIP device.

**No special image is needed** — the same `comfyui-rocm` image
works for iGPUs and discrete GPUs. The host prerequisites are
identical (amdgpu driver + ROCm userspace + user in render/video
groups). The container flags are identical
(`--device /dev/kfd --device /dev/dri --group-add video`).

### Effective VRAM

`rocm-smi` will show a small `VRAM Total Memory` (the BIOS-allocated
partition, typically 512 MB to 4 GB on consumer APUs), but
`torch.cuda.get_device_properties(0).total_memory` reports a much
larger number because the torch runtime can map system RAM as
general-purpose VRAM via unified memory.

Observed on a Ryzen AI 7 350 (Radeon 860M) with 30 GB system RAM:

```
rocm-smi --showmeminfo vram:
    VRAM Total Memory: 536870912 B  (512 MB — the BIOS partition)
    VRAM Total Used:   363008000 B  (346 MB — host display overhead)

torch.cuda.get_device_properties(0).total_memory:
    15,684 MB  (15.3 GB — what ComfyUI can actually use)
```

Strix Halo (Ryzen AI Max 388/390/395) can configure the iGPU
partition up to 96 GB, depending on BIOS settings — so a 128 GB
Strix Halo system can give the iGPU 64+ GB of "VRAM" for
heavyweight models (Flux Dev in fp16, Hunyuan Video, etc.).

### Performance

No dedicated VRAM means the iGPU is bandwidth-limited by the
system memory channel. Approximate numbers vs a discrete RDNA 4
card (your R9700 will be ~10-20x faster per step):

| Workload | R9700 (RDNA 4) | Ryzen AI iGPU (RDNA 3.5) |
|----------|----------------|--------------------------|
| SDXL 1024x1024, 20 steps | ~3-5 s | ~30-60 s |
| Flux Dev 1024x1024, 20 steps | ~10-15 s | ~2-5 min |
| Hunyuan Video, 5s clip | ~3-8 min | ~30-90 min |

These are rough orders of magnitude, not benchmarks. Async weight
offloading (ComfyUI default) helps a lot for iGPU inference by
overlapping CPU→GPU transfers with compute.

### Host prerequisites specific to APU

Mostly the same as for discrete AMD GPUs, plus:

- **BIOS iGPU memory allocation** — set this in the BIOS if you
  want a specific partition size. On some boards, the default is
  very small (512 MB). 4-8 GB is reasonable for SDXL/Flux.
- **KFD support on APU** — on older kernels, `amdgpu.support_kfd=0`
  disables KFD for APUs. Newer kernels (6.0+) enable it by
  default. Check with
  `cat /sys/module/amdgpu/parameters/support_kfd` (if 0, add
  `amdgpu.support_kfd=1` to your kernel cmdline and reboot).
- **Power state** — APUs may enter low-power states that prevent
  ROCm from initialising. `rocm-smi --setperfmode high` (needs
  root or video group) wakes them up. Some hosts need this on
  every boot; persist via a systemd unit or udev rule.

### Quick test recipe

```bash
# 1. Verify the iGPU is visible to ROCm on the host
rocm-smi
# Expect: a table with your iGPU, gfx code shown as gfx1150/1151/1152

# 2. Quick container test
docker run --rm \
    --device /dev/kfd --device /dev/dri --group-add video \
    -p 8188:8188 \
    ghcr.io/genesis-scaffolding/comfyui-rocm:latest-rocm-7.2-amd64

# 3. From another terminal, confirm ComfyUI picked up the iGPU
docker exec <container> bash -c \
    '/opt/venv/bin/python -c "import torch; print(torch.cuda.get_device_name(0), torch.cuda.get_device_properties(0).total_memory // 1024**2, \"MB\")"'
# Expect: AMD Radeon 860M Graphics 15684 MB (or your specific iGPU)
```

## Driver compatibility

The ROCm runtime in the base image determines the **minimum** AMD
GPU driver you need on the host. Older host drivers may not load
the device firmware for newer GPUs.

| ROCm in image | Min host kernel | Min `amdgpu` driver |
|---------------|-----------------|---------------------|
| 7.2.x | 6.0+ | 6.0+ (in-kernel, also called `amdgpu` in mainline) |
| 6.4.x | 5.15+ | 6.4.x (ROCm 6.4 release) |
| 6.3.x | 5.15+ | 6.3.x |

For the gfx1201 (R9700) path, you need a 6.0+ kernel (or 5.15+ LTS
with backports). Ubuntu 24.04 ships kernel 6.8 by default; that works.

## Checking your driver version

```bash
# Kernel driver version
dmesg | grep -i amdgpu | head -3

# ROCm userspace version
cat /opt/rocm/.info/version 2>/dev/null || \
    dpkg -l | grep -E 'rocm|amdgpu' | head -5
```

## Confirming ROCm works inside the container

```bash
docker exec -it <container> bash

# Inside the container:
rocm-smi
# Expect: GPU table with your host's GPUs

python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# Expect: True '<your GPU name>'
```

If `torch.cuda.is_available()` returns `False`:

- The `amdgpu` driver isn't loaded on the host (most common cause).
- The host's `amdgpu` driver is too old for the gfx code of your GPU.
- Your user isn't in the `render` and `video` groups, so `/dev/kfd`
  and `/dev/dri/renderD*` aren't accessible.

## Compute capability reference

ROCm uses `gfx` codes instead of NVIDIA's compute capabilities. The
[official AMD table](https://llvm.org/docs/AMDGPUUsage.html#processors)
is authoritative; this is a subset.

### gfx1200/1201 — RDNA 4

- AMD Radeon AI PRO R9700 (gfx1201, 32 GB workstation) ✅
- AMD Radeon RX 9070 XT (gfx1200, 16 GB) ✅
- AMD Radeon RX 9070 (gfx1200) ✅

### gfx1100/1101/1102 — RDNA 3

- AMD Radeon RX 7900 XTX / RX 7900 XT (gfx1100, 24 GB / 20 GB) ✅
- AMD Radeon RX 7800 XT (gfx1101, 16 GB) ✅
- AMD Radeon RX 7700 XT (gfx1101, 12 GB) ✅
- AMD Radeon RX 7600 (gfx1102, 8 GB) ✅

### gfx1030/1031/1032 — RDNA 2

- AMD Radeon RX 6950 XT / 6900 XT / 6800 XT / 6800 (gfx1030, 16-24 GB) ✅
- AMD Radeon RX 6700 XT / 6700 (gfx1031, 10-12 GB) ✅
- AMD Radeon RX 6600 XT / 6600 (gfx1032, 8 GB) ✅

### gfx942/950 — CDNA 2 (datacenter)

- AMD Instinct MI300X (gfx942, 192 GB HBM3) ✅
- AMD Instinct MI325X (gfx950, 256 GB HBM3e) ✅
- AMD Instinct MI355X (gfx950, 288 GB HBM3e) ✅

### gfx908/90a — CDNA (older datacenter)

- AMD Instinct MI100 (gfx908) ✅
- AMD Instinct MI210 / MI250 / MI250X (gfx90a) ✅

## Recommendations by use case

### Personal desktop / workstation (R9700, RX 9070, RX 7900 XTX)

All of these are supported out of the box. R9700 (gfx1201) is the
recommended target — 32 GB VRAM handles SDXL + most fine-tunes with
room to spare.

### Data centre (MI300X, MI300X)

The image works on Instinct cards, though AMD's own
[`rocm/comfyui`](https://hub.docker.com/r/rocm/comfyui) image is
more focused on these (and only supports `gfx942;gfx950`). If you
need Instinct-specific kernel tuning, use AMD's image.

### Older consumer (RX 6000 series)

Works, but PyTorch's gfx1030 build is less battle-tested than the
RDNA 3/4 paths. Expect occasional quirks on MIOpen kernels.

## Additional resources

- **[AMD ROCm documentation](https://rocm.docs.amd.com/)** — install
  guides, release notes, supported hardware matrix
- **[ROCm Docker Hub org](https://hub.docker.com/u/rocm)** — official
  ROCm container images, including `rocm/pytorch`
- **[RDNA 4 architecture overview](https://www.amd.com/en/technologies/rdna-4)** —
  AMD's marketing page for the R9700 / RX 9070 series
- **[amdgpu kernel driver](https://docs.kernel.org/gpu/amdgpu.html)** —
  upstream kernel docs
