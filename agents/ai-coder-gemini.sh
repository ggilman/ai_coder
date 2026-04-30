#!/bin/bash
# ==============================================================================
# AI-CODER-GEMINI.SH | Gemini CLI Variant Overrides
# ==============================================================================

IMAGE_NAME="gemini-engineer-v5"
TOOL_NAME="Gemini"
NEEDS_LITELLM_PROXY=true

build_image() {
    echo -e "${ICON_GEAR} Building Gemini CLI Image..."
    local pm_proxy_cmds; pm_proxy_cmds=$(make_npm_proxy_cmds)
    local pip_proxy_cmds; pip_proxy_cmds=$(make_pip_proxy_cmds)
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-gemini.txt")"
    local mcp_pkgs; mcp_pkgs=$(read_mcp_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-gemini.txt")
    local mcp_pip_pkgs; mcp_pip_pkgs=$(read_mcp_pip_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-gemini.txt")
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs}"
    fi
    build_standard_image "Dockerfile.gemini" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN npm install -g @google/gemini-cli ${mcp_pkgs}${pip_cmd}
RUN gemini --version"
}

configure_workbench() {
    # Store gemini config in the host home dir so auth tokens and session state
    # persist across projects and container restarts, matching Claude's pattern.
    mkdir -p "$HOME/.gemini-config"
    # Always rewrite settings.json so mcpServers paths reflect the current project.
    # Auth is injected via GEMINI_API_KEY env var, so no tokens are stored here.
    cat > "$HOME/.gemini-config/settings.json" <<EOF
{
  "selectedAuthType": "gemini-api-key",
  "theme": "Default",
  "mcpServers": {
$(make_mcp_servers_json "/$WORKSPACE_DIR" standard "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-gemini.txt")
  }
}
EOF
    # gemini-credentials.json is a known-buggy file that Gemini CLI occasionally
    # corrupts (upstream issue #24835). Since we always inject GEMINI_API_KEY via
    # env var, the file is not needed — delete it before each run so the CLI never
    # hits the corrupted-file error and always uses the env var cleanly.
    rm -f "$HOME/.gemini-config/gemini-credentials.json"
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.gemini-config"):/root/.gemini" \
        -e GEMINI_API_KEY="sk-local-bypass" \
        -e GOOGLE_GENERATIVE_AI_API_KEY="sk-local-bypass" \
        -e GEMINI_SANDBOX="false" \
        -e GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:4000" \
        -- "mkdir -p \"/$WORKSPACE_DIR\"; socat TCP-LISTEN:4000,fork,reuseaddr TCP:${GLOBAL_PROXY_NAME}:4000 & trap 'true' EXIT; while true; do sleep 3600; done"
}

execute_tool() {
    exec_in_container \
        -e TERM=xterm-256color -e COLORTERM=truecolor \
        -e GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:4000 \
        "${WORKBENCH_PREFIX}-${PROJECT_ID}" gemini --max_iterations 20
}
