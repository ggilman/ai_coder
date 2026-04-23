#!/bin/bash
# ==============================================================================
# AI-CODER-GEMINI.SH | Gemini CLI Variant Overrides
# ==============================================================================

IMAGE_NAME="gemini-engineer-v1"

get_litellm_config() {
    cat <<EOF
model_list:
  - model_name: gemma-local
    litellm_params:
      model: openai/local
      api_base: http://$GLOBAL_ENGINE_NAME:8080/v1
      api_key: sk-1234
      timeout: 600
      stream_timeout: 600

litellm_settings:
  request_timeout: 600
  drop_params: true
  num_retries: 0
  model_alias_map:
    gemini-2.0-flash: gemma-local
    gemini-2.5-flash: gemma-local
    gemini-2.5-pro: gemma-local
    gemini-1.5-pro: gemma-local
    gemini-1.5-flash: gemma-local
EOF
}

build_image() {
    image_check=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
    if [ -n "$image_check" ]; then return 0; fi

    echo -e "${ICON_GEAR} Building Gemini CLI Image..."

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

    local apt_pkgs; apt_pkgs="$(read_package_list "$SCRIPT_DIR/packages/apt-common.txt") $(read_package_list "$SCRIPT_DIR/packages/apt-gemini.txt")"

    cat > "$LOCAL_STACK_DIR/Dockerfile.gemini" <<DOCKERFILE
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
RUN npm install -g @google/gemini-cli
RUN gemini --version
WORKDIR /workspace
DOCKERFILE

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" -f "$(to_host_path "$LOCAL_STACK_DIR")/Dockerfile.gemini" "$(to_host_path "$LOCAL_STACK_DIR")" || {
        echo -e "${RED}✘ Docker build failed${NC}"; return 1
    }
}

configure_workbench() {
    local config_dir="$LOCAL_STACK_DIR/gemini-config"
    mkdir -p "$config_dir"
    # Gemini CLI reads ~/.gemini/settings.json for provider/model overrides.
    # Point it at our LiteLLM proxy which maps Gemini model names to gemma-local.
    cat > "$config_dir/settings.json" <<EOF
{
  "selectedAuthType": "gemini-api-key",
  "theme": "Default"
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
        -v "$(to_host_path "$LOCAL_STACK_DIR/gemini-config"):/root/.gemini" \
        -e GEMINI_API_KEY="sk-local-bypass" \
        -e GOOGLE_GENERATIVE_AI_API_KEY="sk-local-bypass" \
        -e GEMINI_SANDBOX="false" \
        "$IMAGE_NAME" /bin/bash -c "trap 'true' EXIT; while true; do sleep 3600; done"
}

execute_tool() {
    local container="${WORKBENCH_PREFIX}-${PROJECT_ID}"
    # Gemini CLI is pointed at our LiteLLM proxy via GEMINI_API_BASE.
    # LiteLLM exposes an OpenAI-compatible endpoint; the model alias map routes
    # any Gemini model name to gemma-local running on the local llama.cpp engine.
    local cmd_exec="docker exec -it \
        -e GEMINI_API_BASE=http://${GLOBAL_PROXY_NAME}:4000 \
        -e GOOGLE_API_BASE=http://${GLOBAL_PROXY_NAME}:4000 \
        $container gemini"
    if [ "$IS_GITBASH" = "true" ]; then
        winpty $cmd_exec
    else
        eval $cmd_exec
    fi
}
