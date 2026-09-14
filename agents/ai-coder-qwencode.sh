#!/bin/bash
# ==============================================================================
# AI-CODER-QWENCODE.SH | Qwen Code Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-qwencode"
TOOL_NAME="Qwen Code"

build_image() {
    build_npm_agent_image "Dockerfile.qwencode" "apt-qwencode.txt" "mcp-qwencode.txt" \
        "@qwen-code/qwen-code" "" "RUN qwen --version"
}

configure_workbench() {
    # Store qwen config in the host home dir so auth tokens and session state
    # persist across projects and container restarts, matching Gemini's pattern.
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$HOME/.qwen-config"
    # Always rewrite settings.json so mcpServers paths reflect the current project.
    # Qwen Code (a Gemini CLI fork) speaks plain OpenAI Chat Completions directly
    # against the engine via OPENAI_API_KEY/OPENAI_BASE_URL/OPENAI_MODEL env vars
    # (set in start_workbench) — unlike Gemini CLI it needs no LiteLLM translation,
    # so no tokens are stored in this file either.
    cat > "$HOME/.qwen-config/settings.json" <<EOF
{
  "selectedAuthType": "openai",
  "theme": "Default",
  "mcpServers": {
$(make_agent_mcp_json "/$WORKSPACE_DIR" standard mcp-qwencode.txt)
  }
}
EOF
}

start_workbench() {
    local _model_id="${MODEL_FILE##*/}"; _model_id="${_model_id%.gguf}"
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.qwen-config"):/root/.qwen" \
        -e OPENAI_API_KEY="${LOCAL_API_KEY}" \
        -e OPENAI_BASE_URL="http://$GLOBAL_ENGINE_NAME:$ENGINE_PORT/v1" \
        -e OPENAI_MODEL="$_model_id"
}

execute_tool() {
    # Qwen Code inherits Gemini CLI's --resume (not --continue).
    local _resume=()
    [ "${CONTINUE_SESSION:-false}" = "true" ] && _resume=(--resume)
    exec_in_container \
        -e TERM=xterm-256color -e COLORTERM=truecolor \
        "$WORKBENCH" qwen "${_resume[@]}"
}
