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

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="${BUNDLE_DIR:-$PROJECT_ROOT/bundle}"
BUNDLE_IMAGES_DIR="$BUNDLE_DIR/images"
BUNDLE_MODELS_DIR="$BUNDLE_DIR/models"
BUNDLE_SCRIPTS_DIR="$BUNDLE_DIR/scripts"
BUNDLE_WORK_DIR="$PROJECT_ROOT/.bundle-work"

# Load core library: colors, icons, SMI path, download helpers, image variables
source "$PROJECT_ROOT/libs/ai-coder-core.sh"

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗"
echo -e "║        AI-CODER OFFLINE BUNDLE v1.0          ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo -e "${DIM}Output: ${BUNDLE_DIR}${NC}\n"

check_docker || exit 1

# --- [ VRAM tier selection ] --------------------------------------------------
echo -e "${CYAN}Select the VRAM tier model to include in the bundle:${NC}"
echo -e "  1)  ${MODEL_8GB_DESC}"
echo -e "  2)  ${MODEL_12GB_DESC}"
echo -e "  3)  ${MODEL_16GB_DESC}"
echo -e "  4)  ${MODEL_24GB_DESC}"
echo -e "  5)  ${MODEL_32GB_DESC}"
echo -ne "\nTier [1-5]: "
read -r _tier_sel
case "$_tier_sel" in
    1) TARGET_MODEL_FILE="$MODEL_8GB_FILE";  TARGET_MODEL_URL="$MODEL_8GB_URL";  TARGET_MODEL_DESC="$MODEL_8GB_DESC"  ;;
    2) TARGET_MODEL_FILE="$MODEL_12GB_FILE"; TARGET_MODEL_URL="$MODEL_12GB_URL"; TARGET_MODEL_DESC="$MODEL_12GB_DESC" ;;
    3) TARGET_MODEL_FILE="$MODEL_16GB_FILE"; TARGET_MODEL_URL="$MODEL_16GB_URL"; TARGET_MODEL_DESC="$MODEL_16GB_DESC" ;;
    4) TARGET_MODEL_FILE="$MODEL_24GB_FILE"; TARGET_MODEL_URL="$MODEL_24GB_URL"; TARGET_MODEL_DESC="$MODEL_24GB_DESC" ;;
    5) TARGET_MODEL_FILE="$MODEL_32GB_FILE"; TARGET_MODEL_URL="$MODEL_32GB_URL"; TARGET_MODEL_DESC="$MODEL_32GB_DESC" ;;
    *) echo -e "${RED}✘ Invalid selection.${NC}"; exit 1 ;;
esac
echo -e "${ICON_OK} Model tier: ${CYAN}${TARGET_MODEL_DESC}${NC}"

# --- [ Create bundle directory structure ] ------------------------------------
echo -e "\n${ICON_GEAR} Preparing bundle directories..."
mkdir -p "$BUNDLE_IMAGES_DIR" "$BUNDLE_MODELS_DIR" "$BUNDLE_SCRIPTS_DIR" "$BUNDLE_WORK_DIR"

# --- [ Copy project scripts ] -------------------------------------------------
echo -e "${ICON_GEAR} Copying project scripts..."
for _item in ai-coder ai-status.sh agents libs packages README.md; do
    [ -e "$PROJECT_ROOT/$_item" ] || continue
    cp -r "$PROJECT_ROOT/$_item" "$BUNDLE_SCRIPTS_DIR/"
done
echo -e "${ICON_OK} Scripts copied."

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

    _tar_path="$BUNDLE_IMAGES_DIR/${_agent_tag}.tar.gz"
    if [ -f "$_tar_path" ]; then
        echo -e "    ${DIM}[already saved in bundle]${NC}"
    else
        echo -e "    Saving image..."
        docker save "$IMAGE_NAME" | gzip > "$_tar_path"
        echo -e "    ${ICON_OK} Saved → ${_agent_tag}.tar.gz"
    fi
done

# --- [ Write bundle manifest ] ------------------------------------------------
cat > "$BUNDLE_DIR/bundle.manifest" <<MANIFEST
model_file=${TARGET_MODEL_FILE}
model_desc=${TARGET_MODEL_DESC}
bundle_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
MANIFEST

# --- [ Embed unbundle script ] ------------------------------------------------
cp "$SCRIPT_DIR/unbundle.sh" "$BUNDLE_DIR/unbundle.sh"
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
