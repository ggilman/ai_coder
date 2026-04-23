#!/bin/bash
# ==============================================================================
# AI-CODER-CLAUDE.SH | Claude-Code Variant Overrides
# ==============================================================================

IMAGE_NAME="claude-engineer-v4-8"
TOOL_NAME="Claude"

build_image() {
    echo -e "${ICON_GEAR} Building Coder Image..."
    local pm_proxy_cmds; pm_proxy_cmds=$(make_npm_proxy_cmds)
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-claude.txt")"
    build_standard_image "Dockerfile" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN npm install -g @anthropic-ai/claude-code --quiet"
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    [ -f "$HOME/.claude-config.json" ] || echo '{}' > "$HOME/.claude-config.json"
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.claude-config"):/root/.claude" \
        -v "$(to_host_path "$HOME/.claude-config.json"):/root/.claude.json" \
        -e ANTHROPIC_BASE_URL="http://$GLOBAL_ENGINE_NAME:8080" \
        -e ANTHROPIC_API_KEY="sk-local-bypass"
}

execute_tool() {
    exec_in_container -e CLAUDE_CODE_SIMPLE=1 "${WORKBENCH_PREFIX}-${PROJECT_ID}" claude --bare
}
