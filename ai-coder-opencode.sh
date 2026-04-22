#!/bin/bash
# ==============================================================================
# AI-CODER-OPENCODE.SH | OpenCode Variant Overrides
# ==============================================================================

IMAGE_NAME="opencode-engineer-v1"

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
        local build_proxy="$DOWNLOAD_PROXY"
        local _proxy_host; _proxy_host=$(echo "$DOWNLOAD_PROXY" | sed 's|.*://||;s|:.*||')
        local _proxy_ip; _proxy_ip=$(getent hosts "$_proxy_host" 2>/dev/null | awk '{print $1}' | head -1)
        [ -n "$_proxy_ip" ] && build_proxy=$(echo "$DOWNLOAD_PROXY" | sed "s/$_proxy_host/$_proxy_ip/")
        proxy_args=(--build-arg "PROXY_URL=$build_proxy")
        npm_proxy_cmds="RUN npm config set proxy $build_proxy && npm config set https-proxy $build_proxy && npm config set strict-ssl false"
    fi

    cat > "$LOCAL_STACK_DIR/Dockerfile.oc" <<DOCKERFILE
FROM node:20-bullseye-slim
ARG PROXY_URL
ENV http_proxy=\${PROXY_URL} https_proxy=\${PROXY_URL} HTTP_PROXY=\${PROXY_URL} HTTPS_PROXY=\${PROXY_URL} \
    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    tree ripgrep curl git \
    --no-install-recommends && rm -rf /var/lib/apt/lists/*
${npm_proxy_cmds}
RUN npm install -g opencode-ai
RUN opencode --version
WORKDIR /workspace
DOCKERFILE

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" -f "$LOCAL_STACK_DIR/Dockerfile.oc" "$LOCAL_STACK_DIR" || {
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
    local cmd_exec="docker exec -it $container opencode"
    if [ "$IS_GITBASH" = "true" ]; then
        winpty $cmd_exec
    else
        eval $cmd_exec
    fi
}
