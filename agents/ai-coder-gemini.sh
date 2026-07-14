#!/bin/bash
# ==============================================================================
# AI-CODER-GEMINI.SH | Gemini CLI Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-gemini"
TOOL_NAME="Gemini"
NEEDS_LITELLM_PROXY=true

build_image() {
    build_npm_agent_image "Dockerfile.gemini" "apt-gemini.txt" "mcp-gemini.txt" \
        "@google/gemini-cli" "" "RUN gemini --version"
}

configure_workbench() {
    # Store gemini config in the host home dir so auth tokens and session state
    # persist across projects and container restarts, matching Claude's pattern.
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$HOME/.gemini-config"
    # Always rewrite settings.json so mcpServers paths reflect the current project.
    # Auth is injected via GEMINI_API_KEY env var, so no tokens are stored here.
    cat > "$HOME/.gemini-config/settings.json" <<EOF
{
  "selectedAuthType": "gemini-api-key",
  "theme": "Default",
  "mcpServers": {
$(make_agent_mcp_json "/$WORKSPACE_DIR" standard mcp-gemini.txt)
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
        "$WORKBENCH" gemini --max_iterations 20
}
