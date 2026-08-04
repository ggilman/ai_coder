#!/bin/bash
# ==============================================================================
# BUNDLE.SH v1.0 | Offline Bundle Creator
# Packages all scripts, Docker images, and a model into a self-contained bundle
# that can be transferred to and deployed on an isolated (air-gapped) system.
#
# Usage: ./bundle.sh
#
# What it produces (in bundle/):
#   scripts/   — copy of all ai-coder project files
#   images/    — all required Docker images saved as gzipped tars
#   models/    — the GGUF model file for the chosen VRAM tier
#   unbundle.sh — companion installer script
#   bundle.manifest — metadata used by unbundle.sh
# ==============================================================================
set -euo pipefail

OFFLINE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PROJECT_ROOT="$(dirname "$OFFLINE_DIR")"
BUNDLE_DIR="${BUNDLE_DIR:-$PROJECT_ROOT/bundle}"
BUNDLE_IMAGES_DIR="$BUNDLE_DIR/images"
BUNDLE_MODELS_DIR="$BUNDLE_DIR/models"
BUNDLE_SCRIPTS_DIR="$BUNDLE_DIR/scripts"
BUNDLE_WORK_DIR="$PROJECT_ROOT/.bundle-work"
FAMILIES_DIR="$PROJECT_ROOT/config/families"

# Load core library: colors, icons, SMI path, download helpers, image variables
source "$PROJECT_ROOT/libs/ai-coder-core.sh"
# Load UI helpers: gum dialogs with plain-read fallback (ensure_gum, ui_init, _gum_choose)
source "$PROJECT_ROOT/libs/ai-coder-ui.sh"
source "$PROJECT_ROOT/libs/ai-coder-setup.sh"

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗"
echo -e "║        AI-CODER OFFLINE BUNDLE v1.0          ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo -e "${DIM}Output: ${BUNDLE_DIR}${NC}\n"

check_docker || exit 1

# Bootstrap gum once for both selection prompts below; falls back to plain
# numbered prompts if gum can't be installed or run (or with AI_CODER_NO_GUM=1).
ensure_gum
ui_init

# --- [ Helper: gum-or-plain single-choice picker ] ----------------------------
# Usage: _bundle_choose <prompt> <name> [name...]
# Echoes the chosen 1-based index on stdout; exits 1 on invalid/cancelled input.
_bundle_choose() {
    local prompt="$1"; shift
    local names=("$@")

    if [ "$UI_GUM" = "true" ]; then
        local choice
        choice=$(_gum_choose "$prompt" "" "" "" "${names[@]}")
        if [ -z "$choice" ]; then
            echo -e "${RED}✘ No selection made.${NC}" >&2
            exit 1
        fi
        local i
        for i in "${!names[@]}"; do
            if [ "${names[$i]}" = "$choice" ]; then
                echo $(( i + 1 ))
                return 0
            fi
        done
        echo -e "${RED}✘ Invalid selection.${NC}" >&2
        exit 1
    fi

    echo -e "${CYAN}${prompt}${NC}" >&2
    local i=1
    for _n in "${names[@]}"; do
        echo -e "  $i)  $_n" >&2
        (( i++ ))
    done
    echo -ne "\nSelection [1-${#names[@]}]: " >&2
    local sel
    read -r sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#names[@]} )); then
        echo -e "${RED}✘ Invalid selection.${NC}" >&2
        exit 1
    fi
    echo "$sel"
}

# --- [ Family selection ] ----------------------------------------------------
_bundle_family_pairs=()
for _f in "$FAMILIES_DIR"/*.conf; do
    [ -f "$_f" ] || continue
    _fname=$(grep -m1 '^MODEL_FAMILY=' "$_f" | sed 's/^MODEL_FAMILY=//;s/"//g;s/\${[^:]*:-//;s/}//')
    [ -n "$_fname" ] || continue
    _fkey=$(basename "$_f" .conf)
    _bundle_family_pairs+=("$_fname:$_fkey")
done
IFS=$'\n' _bundle_family_pairs=($(printf '%s\n' "${_bundle_family_pairs[@]}" | sort)); unset IFS

if [ ${#_bundle_family_pairs[@]} -eq 0 ]; then
    echo -e "${RED}✘ No family confs found in ${FAMILIES_DIR}${NC}"
    exit 1
fi

_bundle_family_names=()
for _pair in "${_bundle_family_pairs[@]}"; do
    _bundle_family_names+=("${_pair%%:*}")
done
_family_sel=$(_bundle_choose "Select the model family to bundle:" "${_bundle_family_names[@]}")
FAMILY_CONF_KEY="${_bundle_family_pairs[$((_family_sel-1))]#*:}"
FAMILY_CONF_DISPLAY="${_bundle_family_pairs[$((_family_sel-1))]%%:*}"
source "$FAMILIES_DIR/${FAMILY_CONF_KEY}.conf"
echo -e "${ICON_OK} Family: ${CYAN}${FAMILY_CONF_DISPLAY}${NC}"

# --- [ Model selection ] ------------------------------------------------------
_bundle_model_names=()
_bmi=1
while true; do
    _bmfv="MODEL_${_bmi}_FILE"
    [ -z "${!_bmfv:-}" ] && break
    _bmdv="MODEL_${_bmi}_DESC"
    _bundle_model_names+=("${!_bmdv:-${!_bmfv}}")
    _bmi=$(( _bmi + 1 ))
done
_model_sel=$(_bundle_choose "Select the model to include in the bundle:" "${_bundle_model_names[@]}")
_bmfv="MODEL_${_model_sel}_FILE";  TARGET_MODEL_FILE="${!_bmfv}"
_bmuv="MODEL_${_model_sel}_URL";   TARGET_MODEL_URL="${!_bmuv}"
_bmdv="MODEL_${_model_sel}_DESC";  TARGET_MODEL_DESC="${!_bmdv:-$TARGET_MODEL_FILE}"
echo -e "${ICON_OK} Model: ${CYAN}${TARGET_MODEL_DESC}${NC}"

# --- [ Create bundle directory structure ] ------------------------------------
echo -e "\n${ICON_GEAR} Preparing bundle directories..."
mkdir -p "$BUNDLE_IMAGES_DIR" "$BUNDLE_MODELS_DIR" "$BUNDLE_SCRIPTS_DIR" "$BUNDLE_WORK_DIR"

# --- [ Copy project scripts ] -------------------------------------------------
echo -e "${ICON_GEAR} Copying project scripts..."
for _item in ai-coder ai-status.sh agents libs config packages README.md; do
    [ -e "$PROJECT_ROOT/$_item" ] || continue
    cp -r "$PROJECT_ROOT/$_item" "$BUNDLE_SCRIPTS_DIR/"
done
echo -e "${ICON_OK} Scripts copied."

# --- [ Gum interface engine ] --------------------------------------------------
# The target machine has no internet access, so gum can't bootstrap itself
# there — fetch both platform builds here (cached in the project's own
# .assets so repeat bundle runs don't re-download) and ship them inside the
# bundle at scripts/.assets. ai-coder-ui.sh finds gum at that exact path
# relative to libs/, so --setup/--menu/--status get gum-powered prompts on
# the air-gapped target with no extra wiring needed.
echo -e "\n${ICON_GEAR} Bundling gum interface engine..."
mkdir -p "$BUNDLE_SCRIPTS_DIR/.assets"
_gum_bundle_ok=true
if _download_gum_binary "Windows" "x86_64" "$PROJECT_ROOT/.assets"; then
    cp "$PROJECT_ROOT/.assets/gum.exe" "$BUNDLE_SCRIPTS_DIR/.assets/gum.exe"
else
    _gum_bundle_ok=false
fi
if _download_gum_binary "Linux" "x86_64" "$PROJECT_ROOT/.assets"; then
    cp "$PROJECT_ROOT/.assets/gum" "$BUNDLE_SCRIPTS_DIR/.assets/gum"
else
    _gum_bundle_ok=false
fi
if [ "$_gum_bundle_ok" = "true" ]; then
    echo -e "${ICON_OK} Gum interface engine bundled (Windows + Linux)."
else
    echo -e "${YELLOW}⚠ Gum download incomplete — target will fall back to plain-text prompts.${NC}"
fi

# --- [ Model ] ----------------------------------------------------------------
echo -e "\n${ICON_GEAR} Model: ${CYAN}${TARGET_MODEL_FILE}${NC}"
BUNDLE_MODEL_PATH="$BUNDLE_MODELS_DIR/$TARGET_MODEL_FILE"

if [ -f "$BUNDLE_MODEL_PATH" ]; then
    echo -e "${ICON_OK} Already in bundle. ${DIM}(skipped)${NC}"
else
    MODEL_FILE="$TARGET_MODEL_FILE"
    if [ ! -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${ICON_GEAR} Downloading ${TARGET_MODEL_DESC}..."
        download_model || { echo -e "${RED}✘ Model download failed.${NC}"; exit 1; }
    fi
    echo -e "${ICON_GEAR} Copying model to bundle..."
    cp "$MODEL_STORAGE_DIR/$MODEL_FILE" "$BUNDLE_MODEL_PATH"
    echo -e "${ICON_OK} Model bundled."
fi

# Bundle the family's speculative-decoding draft model too, if it defines one,
# so spec decoding works on the air-gapped target.
if [ -n "${MODEL_DRAFT_FILE:-}" ]; then
    _bundle_draft_path="$BUNDLE_MODELS_DIR/$MODEL_DRAFT_FILE"
    if [ -f "$_bundle_draft_path" ]; then
        echo -e "${ICON_OK} Draft model already in bundle. ${DIM}(skipped)${NC}"
    else
        if [ ! -f "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" ]; then
            download_draft_model || echo -e "${YELLOW}⚠ Draft model download failed — bundling without it.${NC}"
        fi
        if [ -f "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" ]; then
            cp "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" "$_bundle_draft_path"
            echo -e "${ICON_OK} Draft model bundled (speculative decoding)."
        fi
    fi
fi

# --- [ Helper: save a Docker image to the bundle ] ----------------------------
ensure_image_saved() {
    local image="$1" tag="$2"
    local tar_path="$BUNDLE_IMAGES_DIR/${tag}.tar.gz"
    if [ -f "$tar_path" ]; then
        echo -e "  ${DIM}[cached]${NC} ${tag}.tar.gz"
        return 0
    fi
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo -e "  ${ICON_GEAR} Pulling ${CYAN}${image}${NC}..."
        docker pull "$image" || { echo -e "  ${RED}✘ Pull failed: ${image}${NC}"; return 1; }
    fi
    echo -e "  ${ICON_GEAR} Saving ${CYAN}${image}${NC}..."
    docker save "$image" | gzip > "$tar_path"
    echo -e "  ${ICON_OK} Saved → ${tag}.tar.gz"
}

# --- [ Infrastructure images ] ------------------------------------------------
echo -e "\n${ICON_GEAR} Bundling infrastructure images..."
ensure_image_saved "$LLAMA_IMAGE"   "llama-cpp-server"
ensure_image_saved "$LITELLM_IMAGE" "litellm-proxy"
ensure_image_saved "$BASE_IMAGE"    "node-base"

# --- [ Agent images ] ---------------------------------------------------------
echo -e "\n${ICON_GEAR} Building and bundling agent images..."

for _agent_script in "$PROJECT_ROOT/agents"/ai-coder-*.sh; do
    [ -f "$_agent_script" ] || continue

    # Reset per-agent state before each source so previous values don't bleed in
    NEEDS_LITELLM_PROXY=false
    IMAGE_NAME=""
    TOOL_NAME=""
    # Stub hooks — overwritten by the agent source below
    build_image()         { echo -e "${RED}✘ build_image not set${NC}"; return 1; }
    configure_workbench() { :; }
    start_workbench()     { :; }
    execute_tool()        { :; }

    source "$_agent_script"
    [ -n "${IMAGE_NAME:-}" ] || continue

    _agent_tag="agent-$(echo "$IMAGE_NAME" | tr ':/.' '---')"
    echo -e "  ${BOLD}${TOOL_NAME:-$(basename "$_agent_script")}${NC} → ${CYAN}${IMAGE_NAME}${NC}"

    # Give each agent its own work dir so generated Dockerfiles don't collide
    LOCAL_STACK_DIR="$BUNDLE_WORK_DIR/$IMAGE_NAME"
    mkdir -p "$LOCAL_STACK_DIR"

    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo -e "    ${DIM}[already in Docker cache]${NC}"
    else
        echo -e "    Building image..."
        build_image || { echo -e "    ${RED}✘ Build failed for ${IMAGE_NAME}${NC}"; exit 1; }
    fi

    # build_image above already guarantees the image exists locally, so the
    # pull branch inside ensure_image_saved never triggers here — it's just
    # reused for its cache-check + save + report logic.
    ensure_image_saved "$IMAGE_NAME" "$_agent_tag"
done

# --- [ Write bundle manifest ] ------------------------------------------------
cat > "$BUNDLE_DIR/bundle.manifest" <<MANIFEST
model_family=${FAMILY_CONF_DISPLAY}
model_file=${TARGET_MODEL_FILE}
model_desc=${TARGET_MODEL_DESC}
bundle_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
MANIFEST

# --- [ Embed unbundle script ] ------------------------------------------------
cp "$OFFLINE_DIR/unbundle.sh" "$BUNDLE_DIR/unbundle.sh"
chmod +x "$BUNDLE_DIR/unbundle.sh"

# Cleanup temp Dockerfile artifacts
rm -rf "$BUNDLE_WORK_DIR"

# --- [ Summary ] --------------------------------------------------------------
_bundle_size=$(du -sh "$BUNDLE_DIR" 2>/dev/null | cut -f1 || echo "?")
echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║  ✔  Bundle complete!                         ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo -e "  Location: ${CYAN}${BUNDLE_DIR}${NC}"
echo -e "  Size:     ${CYAN}${_bundle_size}${NC}"
echo -e ""
echo -e "Transfer the ${BOLD}$(basename "$BUNDLE_DIR")/${NC} folder to the target machine."
echo -e "On the target machine, run: ${BOLD}./unbundle.sh${NC}"
