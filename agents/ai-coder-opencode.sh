#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="opencode-engineer-v1"
TOOL_NAME="OpenCode"

build_image() {
    echo -e "${ICON_GEAR} Building OpenCode Image..."
    local pm_proxy_cmds=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
        local npm_proxy; npm_proxy=$(echo "$build_proxy" | sed 's|^https://|http://|')
        pm_proxy_cmds="RUN npm config set proxy $npm_proxy && npm config set https-proxy $npm_proxy && npm config set strict-ssl false"
    fi
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-opencode.txt")"
    build_standard_image "Dockerfile.oc" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN npm install -g opencode-ai
RUN opencode --version"
}

configure_workbench() {
    local config_dir="$LOCAL_STACK_DIR/opencode-config"
    mkdir -p "$config_dir"
    cat > "$config_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "permission": {
    "write": "deny"
  },
  "model": "local/gemma-local",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Gemma (llama.cpp)",
      "options": {
        "baseURL": "http://$GLOBAL_PROXY_NAME:4000/v1",
        "apiKey": "sk-local-bypass"
      },
      "models": {
        "gemma-local": {
          "name": "Gemma 4 Local",
          "contextLength": 65536
        }
      }
    }
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
