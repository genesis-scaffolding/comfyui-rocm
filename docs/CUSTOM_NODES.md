# Custom nodes

The image ships with **ComfyUI-Manager** and **ComfyUI-Impact-Pack**
pre-installed. Adding more is a two-step process:

## Step 1: clone the extension

Append an `install_extension` line to `extensions.sh` (kept
alphabetical by slug):

```bash
# examples
install_extension comfyui_controlnet_aux https://github.com/Fannovel16/comfyui_controlnet_aux.git
install_extension was-node-suite-comfyui     https://github.com/WASasquatch/was-node-suite-comfyui.git
```

On the next container start, the entrypoint clones (or updates) the
extension into `/opt/comfyui/app/custom_nodes/<slug>/` and re-applies
any patches from `patches/<slug>/`.

## Step 2: install the extension's Python deps

The entrypoint's runtime `uv pip install` only reads
`/opt/comfyui/requirements.in` — it does **not** walk every
`custom_nodes/*/requirements.txt`. You need to add the extension's
deps to `requirements.in` explicitly.

**Two ways to do this:**

### Option A: pull the extension's requirements file directly

```python
# https://github.com/<owner>/<repo>
-r "https://raw.githubusercontent.com/<owner>/<repo>/refs/heads/main/requirements.txt"
```

**Pros:** one line, the extension's deps update when the extension
updates. **Cons:** depends on the extension having a
`requirements.txt` at that path on that branch.

### Option B: pin individual packages

```python
# https://github.com/<owner>/<repo>
package-a
package-b==1.2.3
package-c>=2.0
```

**Pros:** explicit, reproducible. **Cons:** more lines, have to track
when the extension's deps change.

## Adding a new custom node — checklist

1. Add `install_extension <slug> <url>` to `extensions.sh`
2. Add the extension's requirements to `requirements.in` under a
   slug-keyed block, alphabetically
3. If the extension needs local fixes, drop a patch in
   `patches/<slug>/<NNN>-<desc>.patch` (see `patches/README.md`)
4. Open a PR. The CI rebuilds the image on merge.

## Installing extra deps in a running container (no rebuild)

If you want to add a node's deps without rebuilding the image
(useful for one-off experiments or while waiting for a rebuild):

```bash
docker exec <container> /opt/venv/bin/pip install <packages...>
# or
docker exec <container> /opt/venv/bin/pip install \
    -r /opt/comfyui/app/custom_nodes/<slug>/requirements.txt
```

These installs persist in the container's `/opt/venv` until the
container is removed. If you bind-mount the venv to host
(`./data/python:/opt/comfyui/python`, as in `compose.yaml`), the
installs also persist across container recreates.
