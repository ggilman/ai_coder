#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-opencode"
TOOL_NAME="OpenCode"

build_image() {
    build_npm_agent_image "Dockerfile.oc" "apt-opencode.txt" "mcp-opencode.txt" \
        "opencode-ai" "" "RUN opencode --version"
}

configure_workbench() {
    local config_dir="$HOME/.opencode-config"
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$config_dir"
    cat > "$config_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "permission": {
    "write": "deny"
  },
  "model": "local/hub-model",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local $MODEL_FAMILY (llama.cpp)",
      "options": {
        "baseURL": "http://$GLOBAL_ENGINE_NAME:8080/v1",
        "apiKey": "$LOCAL_API_KEY"
      },
      "models": {
        "hub-model": {
          "name": "$MODEL_FAMILY Local",
          "contextLength": $MODEL_CTX_SIZE
        }
      }
    }
  },
  "mcp": {
$(make_agent_mcp_json "/$WORKSPACE_DIR" opencode mcp-opencode.txt)
  }
}
EOF
}

start_workbench() {
    run_workbench \
        -e OPENCODE_DISABLE_MODELS_FETCH=1 \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.opencode-config"):/root/.config/opencode" \
        -v "$(to_host_path "$PACKAGES_DIR/opencode-pty.py"):/opt/opencode-pty.py:ro"
}

execute_tool() {
    # Run through a PTY wrapper (packages/opencode-pty.py) instead of `opencode`
    # directly — OpenCode doesn't handle Ctrl-C well from inside a docker exec
    # TTY, and the wrapper strips it from the input stream instead.
    exec_in_container "$WORKBENCH" python3 /opt/opencode-pty.py
}
