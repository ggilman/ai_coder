#!/bin/bash
# ==============================================================================
# AI-CODER-AIDER.SH | Aider Variant Overrides
# ==============================================================================

IMAGE_NAME="aider-engineer-v1"
TOOL_NAME="Aider"

build_image() {
    echo -e "${ICON_GEAR} Building Aider Image..."
    local pm_proxy_cmds=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
        pm_proxy_cmds="RUN pip config set global.proxy $build_proxy && pip config set global.trusted-host pypi.org"
    fi
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-aider.txt")"
    build_standard_image "Dockerfile.aider" "$apt_pkgs" "$pm_proxy_cmds" \
        "RUN python3 -m venv /opt/aider && /opt/aider/bin/pip install aider-chat
RUN /opt/aider/bin/aider --version"
}

configure_workbench() {
    mkdir -p "$HOME/.aider-config"
    # Always write gitconfig so the container has git identity via GIT_CONFIG_GLOBAL
    cat > "$HOME/.aider-config/.gitconfig" <<EOF
[user]
    name = $GIT_USER_NAME
    email = $GIT_USER_EMAIL
EOF
    # Only write aider config on first run so user customisations persist
    if [ ! -f "$HOME/.aider-config/.aider.conf.yml" ]; then
        cat > "$HOME/.aider-config/.aider.conf.yml" <<EOF
openai-api-base: http://$GLOBAL_ENGINE_NAME:8080/v1
openai-api-key: sk-local-bypass
model: openai/local
no-auto-commits: false
check-update: false
show-model-warnings: false
show-release-notes: false
gitignore: true
input-history-file: /root/.aider-config/.aider.input.history
EOF
    fi
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    run_workbench \
        -v "$(to_host_path "$HOME/.aider-config"):/root/.aider-config" \
        -v "$(to_host_path "$HOME/.aider-config/.gitconfig"):/root/.gitconfig:ro" \
        -e OPENAI_API_BASE="http://$GLOBAL_ENGINE_NAME:8080/v1" \
        -e OPENAI_API_KEY="sk-local-bypass"
}

execute_tool() {
    exec_in_container \
        -e TERM=xterm-256color -e COLORTERM=truecolor \
        "${WORKBENCH_PREFIX}-${PROJECT_ID}" /opt/aider/bin/aider --no-check-update --config /root/.aider-config/.aider.conf.yml
}
