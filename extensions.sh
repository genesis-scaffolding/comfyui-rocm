# shellcheck disable=SC2148
#
# Pre-installed ComfyUI extensions. Each `install_extension` call is
# idempotent: on first run it clones, on subsequent runs it does a
# fast-forward update. Patches in patches/<slug>/ are re-applied on
# every start (see entrypoint.sh -> patch_extension).
#
# Keep entries sorted alphabetically by slug.

# ComfyUI Impact Pack — detector/detailer nodes (face detailers, SAM,
# YOLO, etc.). Common prerequisite for video and face workflows.
# Python deps are listed in requirements.in under the `# comfyui-impact-pack`
# block. Auto-cloned; entrypoint re-installs deps on every start.
install_extension comfyui-impact-pack https://github.com/ltdrdata/ComfyUI-Impact-Pack.git

# ComfyUI Manager — the only extension shipped in v1. Manager provides
# the in-UI extension browser, which is how users install everything
# else.
install_extension comfyui-manager https://github.com/ltdrdata/ComfyUI-Manager.git
