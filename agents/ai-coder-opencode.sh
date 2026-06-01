#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="opencode-engineer-v2"
TOOL_NAME="OpenCode"

build_image() {
    echo -e "${ICON_GEAR} Building OpenCode Image..."
    local pm_proxy_cmds; pm_proxy_cmds=$(make_npm_proxy_cmds)
    local pip_proxy_cmds; pip_proxy_cmds=$(make_pip_proxy_cmds)
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-opencode.txt")"
    local mcp_pkgs; mcp_pkgs=$(read_mcp_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-opencode.txt")
    local mcp_pip_pkgs; mcp_pip_pkgs=$(read_mcp_pip_packages --offline "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-opencode.txt")
    local mcp_pip_online; mcp_pip_online=$(read_mcp_pip_packages --online "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-opencode.txt")
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs}"
    fi
    if [ -n "$(echo "$mcp_pip_online" | tr -d ' ')" ]; then
        pip_cmd+=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_online} || true"
    fi
    build_standard_image "Dockerfile.oc" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN npm install -g opencode-ai ${mcp_pkgs}${pip_cmd}
RUN opencode --version"
}

configure_workbench() {
    local config_dir="$LOCAL_STACK_DIR/opencode-config"
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    elif [ ! -w "$config_dir" ]; then
        sudo chown -R "$USER" "$config_dir"
    fi
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
$(make_mcp_servers_json "/$WORKSPACE_DIR" opencode "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-opencode.txt")
  }
}
EOF
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    run_workbench \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$LOCAL_STACK_DIR/opencode-config"):/root/.config/opencode"
}

execute_tool() {
    exec_in_container "${WORKBENCH_PREFIX}-${PROJECT_ID}" opencode
}
