#!/bin/bash
# ComfyUI container entrypoint.
#
# Responsibilities (in order):
#   1. Create the directory layout ComfyUI expects.
#   2. Drop from root to the configured PUID/PGID.
#   3. Sync any extensions listed in extensions.sh (idempotent).
#   4. Ensure the Python venv matches requirements.in.
#   5. Initialise ComfyUI-Manager's config (if Manager is installed).
#   6. Start ComfyUI.

set -eu

# Locations
COMFYUI_HOME="${COMFYUI_HOME:-/opt/comfyui}"
COMFYUI_APP_DIR="${COMFYUI_HOME}/app"
COMFYUI_CUSTOM_NODES_DIR="${COMFYUI_APP_DIR}/custom_nodes"
COMFYUI_MODELS_DIR="${COMFYUI_APP_DIR}/models"
COMFYUI_PROFILE_DIR="${COMFYUI_APP_DIR}/user"
COMFYUI_PATCHES_DIR="${COMFYUI_HOME}/patches"

# Run-as settings
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# The rocm/pytorch base ships a pre-built /opt/venv with torch+rocm
# matched. We do NOT create our own venv — extension requirements are
# installed into the base venv via uv pip install.
PYTHON_BIN="${PYTHON_BIN:-/opt/venv/bin/python}"

_is_sourced() {
    # https://unix.stackexchange.com/a/215279
    [ "${#FUNCNAME[@]}" -ge 2 ] \
        && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
        && [ "${FUNCNAME[1]}" = 'source' ]
}

log() {
    printf "\033[37m** %s\033[0m\n" "$*"
}

# Idempotent extension installer. Called from extensions.sh.
function install_extension() {
    local name="$1"; shift
    local url="$1"; shift

    if [[ ! -d "${COMFYUI_CUSTOM_NODES_DIR}/${name}" ]]; then
        log "Installing ${name}..."
        git clone "${url}" "${COMFYUI_CUSTOM_NODES_DIR}/${name}" --recurse-submodules
    else
        log "Updating ${name}..."
        (cd "${COMFYUI_CUSTOM_NODES_DIR}/${name}" \
            && git fetch --prune --prune-tags --recurse-submodules \
            && git reset --hard --recurse-submodules "@{upstream}")
    fi

    # Re-applied on every start since fresh clones / hard resets land
    # on unpatched upstream code.
    patch_extension "${name}"
}

# Apply local patches from patches/<slug>/*.patch on top of an
# installed extension. See patches/README.md.
function patch_extension() {
    local name="$1"; shift
    local patch_dir="${COMFYUI_PATCHES_DIR}/${name}"
    local ext_dir="${COMFYUI_CUSTOM_NODES_DIR}/${name}"

    [[ -d "${patch_dir}" ]] || return 0
    [[ -d "${ext_dir}" ]] || { log "Cannot patch ${name}: not installed"; return 1; }

    local patch_file
    for patch_file in "${patch_dir}"/*.patch; do
        [[ -e "${patch_file}" ]] || continue

        if (cd "${ext_dir}" && git apply --check --reverse "${patch_file}" 2>/dev/null); then
            log "Patch $(basename "${patch_file}") already applied to ${name}, skipping..."
            continue
        fi

        log "Applying patch $(basename "${patch_file}") to ${name}..."
        (cd "${ext_dir}" && git apply "${patch_file}")
    done
}

# Create ComfyUI's expected subdirectories if we're still root. Each
# dir is created owned by the comfyui user so fix_perms can skip the
# chown when PUID matches the built-in UID — without leaving freshly-
# created subdirs as root-owned.
function setup_dirs() {
    [[ "$(id -u)" = '0' ]] || return 0

    local comfy_uid comfy_gid
    comfy_uid="$(id -u comfyui)"
    comfy_gid="$(id -g comfyui)"

    local d
    for d in \
        "${COMFYUI_APP_DIR}" \
        "${COMFYUI_CUSTOM_NODES_DIR}" \
        "${COMFYUI_PROFILE_DIR}" \
        "${COMFYUI_APP_DIR}/input" \
        "${COMFYUI_APP_DIR}/output"
    do
        mkdir -p "${d}"
        chown "${comfy_uid}:${comfy_gid}" "${d}"
    done

    # ComfyUI's expected model subdirs (mirrors comfyture's list).
    local model_dir
    for model_dir in \
        audio_encoders checkpoints clip clip_vision configs controlnet \
        depthanything3 diffusers diffusion_models embeddings gligen \
        hypernetworks inpaint insightface ipadapter latent_upscale_models \
        LLM loras model_patches onnx photomaker sams SEEDVR2 style_models \
        text_encoders ultralytics unet upscale_models vae vae_approx vibevoice
    do
        mkdir -p "${COMFYUI_MODELS_DIR}/${model_dir}"
        chown "${comfy_uid}:${comfy_gid}" "${COMFYUI_MODELS_DIR}/${model_dir}"
    done
}

# Fix ownership and drop privileges. Re-execs this script under gosu.
function fix_perms() {
    [[ "$(id -u)" = '0' ]] || return 0

    log "Adjusting ownership to UID=${PUID} GID=${PGID}..."
    groupmod -o -g "${PGID}" comfyui
    usermod -o -u "${PUID}" comfyui

    # Always chown the bind-mount sources. Docker creates them as root
    # on first run, and the previous "skip when /opt/comfyui already
    # matches PUID" optimisation left bind mounts unwriteable for the
    # common case where PUID == 1000 (matching the image's comfyui UID).
    local bind_path
    for bind_path in \
        "${COMFYUI_HOME}/python" \
        "${COMFYUI_APP_DIR}/custom_nodes" \
        "${COMFYUI_MODELS_DIR}" \
        "${COMFYUI_APP_DIR}/input" \
        "${COMFYUI_APP_DIR}/output" \
        "${COMFYUI_APP_DIR}/user"
    do
        [[ -d "${bind_path}" ]] || continue
        find "${bind_path}" \( ! -uid "${PUID}" -o ! -gid "${PGID}" \) \
            -exec chown "${PUID}":"${PGID}" {} +
    done

    log "Dropping to unprivileged user..."
    exec gosu comfyui "$0" "$@"
}

# Initialise ComfyUI-Manager's profile if Manager is installed.
function init_manager() {
    local mgr_dir="${COMFYUI_CUSTOM_NODES_DIR}/comfyui-manager"
    [[ -d "${mgr_dir}" ]] || return 0

    local cfg_dir="${COMFYUI_PROFILE_DIR}/__manager"
    mkdir -p "${cfg_dir}"

    cat > "${cfg_dir}/config.ini" <<'EOF'
[default]
git_exe = /usr/bin/git
use_uv = True
use_unified_resolver = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
always_lazy_install = False
network_mode = personal_cloud
db_mode = cache
verbose = False
EOF
}

function _main() {
    setup_dirs
    fix_perms "$@"

    # Now running as comfyui
    cd "${COMFYUI_HOME}"

    # Sync extensions (clones new ones, updates existing, applies patches)
    if [[ -f "${COMFYUI_HOME}/extensions.sh" ]]; then
        log "Syncing extensions..."
        # shellcheck disable=SC1091
        source "${COMFYUI_HOME}/extensions.sh"
    fi

    # Install / refresh extension requirements into the base's /opt/venv.
    # The base venv already has torch+rocm matched to the runtime —
    # we only layer in additional deps from requirements.in.
    log "Refreshing Python environment..."
    uv pip install --python "${PYTHON_BIN}" --compile-bytecode \
        -r "${COMFYUI_HOME}/requirements.in"
    uv cache prune

    init_manager

    log "Ready. Starting ComfyUI..."

    # Default ComfyUI flags. Disable via COMFYUI_NO_DEFAULTS=true.
    COMFYUI_DEFAULTS=(
        "--listen=0.0.0.0"
        "--disable-auto-launch"
    )
    if [[ -d "${COMFYUI_CUSTOM_NODES_DIR}/comfyui-manager" ]]; then
        COMFYUI_DEFAULTS+=("--enable-manager")
    fi
    if [[ "${COMFYUI_NO_DEFAULTS:-false}" == "true" ]]; then
        COMFYUI_DEFAULTS=()
    fi

    exec "${PYTHON_BIN}" \
        "${COMFYUI_APP_DIR}/main.py" \
        "${COMFYUI_DEFAULTS[@]}" "$@"
}

if ! _is_sourced; then
    _main "$@"
fi
