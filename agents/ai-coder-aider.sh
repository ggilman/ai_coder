#!/bin/bash
# ==============================================================================
# AI-CODER-AIDER.SH | Aider Variant Overrides
# ==============================================================================

IMAGE_NAME="aider-engineer-v1"
TOOL_NAME="Aider"

build_image() {
    image_check=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
    if [ -n "$image_check" ]; then return 0; fi

    echo -e "${ICON_GEAR} Building Aider Image..."

    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        if [ -n "${DOWNLOAD_PROXY:-}" ]; then
            pull_base_image_via_proxy "$BASE_IMAGE" "$DOWNLOAD_PROXY" || return 1
        else
            docker pull "$BASE_IMAGE" || { echo -e "${RED}✘ Base image pull failed${NC}"; return 1; }
        fi
    fi

    local proxy_args=()
    local pip_proxy_cmds=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
        proxy_args=(--build-arg "PROXY_URL=$build_proxy")
        pip_proxy_cmds="RUN pip config set global.proxy $build_proxy && pip config set global.trusted-host pypi.org"
    fi

    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-aider.txt")"

    cat > "$LOCAL_STACK_DIR/Dockerfile.aider" <<DOCKERFILE
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
${pip_proxy_cmds}
RUN pip3 install aider-install && aider-install
RUN aider --version
WORKDIR /workspace
DOCKERFILE

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" -f "$(to_host_path "$LOCAL_STACK_DIR")/Dockerfile.aider" "$(to_host_path "$LOCAL_STACK_DIR")" || {
        echo -e "${RED}✘ Docker build failed${NC}"; return 1
    }
}

configure_workbench() {
    mkdir -p "$HOME/.aider-config"
    # Only write config on first run so user customisations persist
    if [ ! -f "$HOME/.aider-config/.aider.conf.yml" ]; then
        cat > "$HOME/.aider-config/.aider.conf.yml" <<EOF
openai-api-base: http://$GLOBAL_PROXY_NAME:4000/v1
openai-api-key: sk-local-bypass
model: openai/local
no-auto-commits: false
EOF
    fi
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    configure_workbench
    docker run -d --name "$WORKBENCH" --network "$HUB_NETWORK" --privileged \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_PROXY_NAME,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$(pwd)"):/workspace" \
        -v "$(to_host_path "$HOME/.aider-config"):/root/.aider-config" \
        -e OPENAI_API_BASE="http://$GLOBAL_PROXY_NAME:4000/v1" \
        -e OPENAI_API_KEY="sk-local-bypass" \
        "$IMAGE_NAME" /bin/bash -c "trap 'true' EXIT; while true; do sleep 3600; done"
}

execute_tool() {
    local container="${WORKBENCH_PREFIX}-${PROJECT_ID}"
    local cmd_exec="docker exec -it -e TERM=xterm-256color -e COLORTERM=truecolor $container aider --config /root/.aider-config/.aider.conf.yml"
    if [ "$IS_GITBASH" = "true" ]; then
        winpty $cmd_exec
    else
        eval $cmd_exec
    fi
}
