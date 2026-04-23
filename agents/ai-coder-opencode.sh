#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="opencode-engineer-v1"
TOOL_NAME="OpenCode"

build_image() {
    image_check=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
    if [ -n "$image_check" ]; then return 0; fi

    echo -e "${ICON_GEAR} Building OpenCode Image..."

    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        if [ -n "${DOWNLOAD_PROXY:-}" ]; then
            pull_base_image_via_proxy "$BASE_IMAGE" "$DOWNLOAD_PROXY" || return 1
        else
            docker pull "$BASE_IMAGE" || { echo -e "${RED}✘ Base image pull failed${NC}"; return 1; }
        fi
    fi

    local proxy_args=()
    local npm_proxy_cmds=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
        local npm_proxy; npm_proxy=$(echo "$build_proxy" | sed 's|^https://|http://|')
        proxy_args=(--build-arg "PROXY_URL=$build_proxy")
        npm_proxy_cmds="RUN npm config set proxy $npm_proxy && npm config set https-proxy $npm_proxy && npm config set strict-ssl false"
    fi

    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-opencode.txt")"

    cat > "$LOCAL_STACK_DIR/Dockerfile.oc" <<DOCKERFILE
FROM node:20-bullseye-slim
ARG PROXY_URL
ENV DEBIAN_FRONTEND=noninteractive
RUN if [ -n "\${PROXY_URL}" ]; then \
      apt_proxy=\$(echo "\${PROXY_URL}" | sed 's|^https://|http://|') && \
      sed -i 's|http://|https://|g' /etc/apt/sources.list && \
      printf 'Acquire::https::Proxy "%s";\nAcquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' "\${apt_proxy}" > /etc/apt/apt.conf.d/01proxy; \
    fi
RUN apt-get update && apt-get install -y \
    ${apt_pkgs} \
    --no-install-recommends && rm -rf /var/lib/apt/lists/*
ENV http_proxy=\${PROXY_URL} https_proxy=\${PROXY_URL} HTTP_PROXY=\${PROXY_URL} HTTPS_PROXY=\${PROXY_URL} \
    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1
${npm_proxy_cmds}
RUN npm install -g opencode-ai
RUN opencode --version
WORKDIR /workspace
DOCKERFILE

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" -f "$(to_host_path "$LOCAL_STACK_DIR")/Dockerfile.oc" "$(to_host_path "$LOCAL_STACK_DIR")" || {
        echo -e "${RED}✘ Docker build failed${NC}"; return 1
    }
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
    configure_workbench
    docker run -d --name "$WORKBENCH" --network "$HUB_NETWORK" --privileged \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_PROXY_NAME,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$(pwd)"):/workspace" \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$LOCAL_STACK_DIR/opencode-config"):/root/.config/opencode" \
        "$IMAGE_NAME" /bin/bash -c "trap 'true' EXIT; while true; do sleep 3600; done"
}

execute_tool() {
    local container="${WORKBENCH_PREFIX}-${PROJECT_ID}"
    local cmd_exec="docker exec -it $container opencode --max-turns 20"
    if [ "$IS_GITBASH" = "true" ]; then
        winpty $cmd_exec
    else
        eval $cmd_exec
    fi
}
