# Repository Structure

```
genesis-scaffolding/comfyui-rocm/
├── .github/
│   ├── workflows/
│   │   └── build.yml              # The CI: detect → build → release
│   └── ISSUE_TEMPLATE/
│       ├── bug_report.md
│       └── feature_request.md
│
├── docs/
│   ├── QUICKSTART.md              # End-user: how to pull and run the image
│   ├── AMD-GPU-COMPATIBILITY.md   # Supported AMD GPU matrix
│   └── REPOSITORY-STRUCTURE.md    # This file
│
├── scripts/
│   ├── check-releases.sh          # Compare upstream vs our latest tag
│   └── test-build.sh              # Build one cell of the matrix locally
│
├── patches/                       # Local extension patches
│   └── README.md                  # How patches/ works
│
├── Dockerfile                     # Multi-stage: uv + rocm/pytorch
├── docker-bake.hcl                # Build target for `docker buildx bake`
├── entrypoint.sh                  # Container entrypoint
├── extensions.sh                  # Pre-installed custom nodes
├── requirements.in                # Python deps (ComfyUI non-torch + extensions)
├── compose.yaml                   # User-facing compose
├── compose.dev.yaml               # Local-dev override (named volumes)
├── metadata.env                   # Pinned versions for local builds
│
├── data/.keep                     # Marker so the host bind-mount dir is
│                                  #   tracked by git
│
├── .gitignore
├── LICENSE                        # MIT
├── AGENTS.md                      # Notes for future agents
└── README.md                      # Project landing page
```

## File descriptions

### Core CI

#### `.github/workflows/build.yml`

The CI itself. Three jobs:

1. **`check-release`** — queries the Comfy-Org/ComfyUI releases API
   for the latest tag. Compares against the local git tag list. Sets
   `should_build` accordingly.
2. **`build`** — runs the matrix (currently a single amd64 cell).
   Uses a native GitHub-hosted runner (`ubuntu-latest`). Pushes the
   image to GHCR. Tags it as
   `<version>-rocm-<rocm-version-short>-amd64` plus a `latest-...-amd64` alias.
3. **`release`** — publishes a GitHub Release with the body pointing
   at the new image tags. Uses the empty-commit-on-tag trick from
   comfyui-cuda so release list sorts by build time.

#### Triggers

- **Daily cron** at 00:00 UTC.
- **`workflow_dispatch`** with a `force_build` boolean to bypass the
  release-detection check.

### Build inputs

#### `Dockerfile`

Multi-stage:

- Stage 1: pulls the `uv` binary from `ghcr.io/astral-sh/uv`.
- Stage 2: the main image. Based on
  `rocm/pytorch:rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1`.
  Installs OS packages (gosu, curl, gcc, ffmpeg, ...), creates the
  `comfyui` user, copies build inputs, clones ComfyUI at the pinned
  tag, and installs Python deps into the base's pre-built
  `/opt/venv`.

Build args:

- `COMFYUI_VERSION` — required. The upstream tag to clone.
- `ROCM_BASE_TAG` — defaults to `rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.9.1`.
- `UV_VERSION` — defaults to `0.12.5`.

#### `docker-bake.hcl`

Bake config consumed by `docker/bake-action` in CI and
`docker buildx build` locally. Validates that `COMFYUI_VERSION` is
set (the workflow passes it; local builds source it from
`metadata.env`).

#### `entrypoint.sh`

Container entrypoint. Runs as root initially, then drops to
`comfyui` via `gosu` (with `PUID`/`PGID` adjustment). Sources
`extensions.sh` to sync custom nodes, refreshes Python deps against
`requirements.in` (into `/opt/venv`, the base image's pre-built
venv), then starts ComfyUI.

The only material divergence from the comfyui-cuda repo's entrypoint
is that we use `--python /opt/venv/bin/python` to install into the
existing base venv rather than creating our own venv at
`/opt/comfyui/python/venv`.

#### `extensions.sh`

List of pre-installed ComfyUI extensions. Currently just
[ComfyUI-Manager](https://github.com/ltdrdata/ComfyUI-Manager). Add
new extensions via `install_extension <slug> <git-url>`.

#### `requirements.in`

Python dependencies. Does **not** include torch — the base image
already provides a matched torch+rocm combo. Lists:

- ComfyUI's non-torch requirements (fetched from the pinned upstream
  tag)
- ComfyUI-Manager requirements (fetched from upstream)
- Per-extension requirements (under `# CUSTOM NODES`)

No `pylock.toml` is committed — we resolve at build time. Switch to
a committed lock file if reproducibility becomes a concern.

#### `metadata.env`

Pinned versions for local builds. The CI overrides these per run.

### User-facing

#### `compose.yaml`

Standard compose for running the image. Binds host directories for
persistence (Python venv, custom nodes, models, profiles). Pin the
image tag for reproducibility.

ROCm-specific bits:
- `devices: /dev/kfd, /dev/dri` (replaces the CUDA `gpus:` block)
- `group_add: [video]`
- `HIP_VISIBLE_DEVICES=0` env
- `CUDA_VISIBLE_DEVICES=""` env

#### `compose.dev.yaml`

Local-dev override using named volumes. Combine with `compose.yaml`
to test without polluting the host filesystem:

```bash
docker compose -f compose.yaml -f compose.dev.yaml up
```

### Helpers

#### `scripts/check-releases.sh`

Compare upstream's latest release against our local git tags. Useful
for sanity-checking before triggering the CI manually.

#### `scripts/test-build.sh`

Build the image locally for the host's architecture, tagged as
`comfyui-rocm:test-<version>-rocm-<rocm>-amd64`. Runs the same
Dockerfile the CI runs.

### Docs

#### `docs/QUICKSTART.md`

End-user quickstart. Pull the image, run with the ROCm device flags,
install models, install extensions via Manager.

#### `docs/AMD-GPU-COMPATIBILITY.md`

Reference for ROCm 7.2 / PyTorch 2.9.1 supported hardware. Covers
RDNA 4 (R9700, RX 9070), RDNA 3 (RX 7000), and Instinct MI300X /
MI325X / MI355X.

#### `docs/REPOSITORY-STRUCTURE.md`

This file.

## How the build flows end-to-end

```
schedule (cron: 0 0 * * *)  or  workflow_dispatch
                    │
                    ▼
        ┌──────────────────────┐
        │   check-release      │   ubuntu-latest
        │   - GET /releases/   │   ~1 sec
        │     latest           │
        │   - compare against  │
        │     local git tags   │
        └──────────┬───────────┘
                   │ outputs: should_build, release_tag, release_hash
                   ▼
        ┌──────────────────────┐
        │   build              │   matrix: { amd64 } × ROCm 7.2.4
        │   - maximize space   │   native runner
        │   - docker buildx    │
        │     bake             │
        │   - push to GHCR     │   ~25-40 min per cell (large base)
        └──────────┬───────────┘
                   │ needs.build == 'success'
                   ▼
        ┌──────────────────────┐
        │   release            │   ubuntu-latest
        │   - advancing tag    │   ~30 sec
        │   - create GitHub    │
        │     release          │
        └──────────────────────┘
```

## Maintenance

### Add a new ROCm version

1. Edit `.github/workflows/build.yml` — add to the `matrix.include`
   list with a new `rocm_base_tag` and `rocm_version_short`.
2. Edit `metadata.env` — update `ROCM_BASE_TAG` for local builds.
3. Edit `docs/AMD-GPU-COMPATIBILITY.md` — add the new version's GPU
   support notes.

### Add a new host architecture

1. Edit `.github/workflows/build.yml` — add to the `matrix.include`
   list with a suitable `runs_on` runner. Note: the `rocm/pytorch`
   base is amd64-only, so this requires a different base image.
2. Update the README and QUICKSTART tables.

### Pre-install a new custom node

1. Add `install_extension <slug> <url>` to `extensions.sh` (in
   alphabetical order by slug).
2. Add the extension's requirements under a slug-keyed block in
   `requirements.in`.
3. If the extension needs a local fix that isn't upstream yet, add
   `patches/<slug>/<NNN>-<desc>.patch`.
4. Open a PR. The CI rebuilds on merge.

### Bump torch / Python / Ubuntu

All three are encoded in `ROCM_BASE_TAG`. Pick a new tag from
<https://hub.docker.com/r/rocm/pytorch/tags> that supports gfx1201
(R9700) and update the single variable. Bumping is one-line; the
resulting image will track AMD's validated combo for the new
versions.
