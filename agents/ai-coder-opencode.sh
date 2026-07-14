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
    local config_dir="$LOCAL_STACK_DIR/opencode-config"
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
        "apiKey": "sk-local-bypass"
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
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    run_workbench \
        -e OPENCODE_DISABLE_MODELS_FETCH=1 \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$LOCAL_STACK_DIR/opencode-config"):/root/.config/opencode"
}

execute_tool() {
    exec_in_container "$WORKBENCH" opencode
}
