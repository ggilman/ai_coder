#!/bin/bash
# ==============================================================================
# AI-CODER-AIDER.SH | Aider Variant Overrides
# ==============================================================================

IMAGE_NAME="ai-coder-aider"
TOOL_NAME="Aider"

build_image() {
    if [ -n "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then
        echo -e "${ICON_OK} Aider Image: ready."
        return 0
    fi
    echo -e "${ICON_GEAR} Building Aider Image..."
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/apt-aider.txt")"
    local _pip_proxy_flags=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local _build_proxy; _build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
        local _pip_proxy; _pip_proxy=$(echo "$_build_proxy" | sed 's|^https://|http://|')
        _pip_proxy_flags="--proxy $_pip_proxy --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org"
    fi
    build_standard_image "Dockerfile.aider" "$apt_pkgs" "" \
        "RUN env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY python3 -m venv /opt/aider && env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY /opt/aider/bin/pip install aider-chat ${_pip_proxy_flags}
RUN /opt/aider/bin/aider --version"
}

configure_workbench() {
    # Docker runs as root so mounted dir files can become root-owned on the WSL host.
    ensure_host_dir_writable "$HOME/.aider-config"
    # Git identity + autocrlf come from ~/.gitconfig-container, which
    # run_workbench mounts at /root/.gitconfig for every agent.
    # Always write the aider config so the API base URL stays current.
    # User customisations (model, flags) can be made in the file after first run
    # but the connection settings must match the current infrastructure.
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
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    run_workbench \
        -v "$(to_host_path "$HOME/.aider-config"):/root/.aider-config" \
        -e OPENAI_API_BASE="http://$GLOBAL_ENGINE_NAME:8080/v1" \
        -e OPENAI_API_KEY="sk-local-bypass"
}

execute_tool() {
    exec_in_container \
        -e TERM=xterm-256color -e COLORTERM=truecolor \
        "$WORKBENCH" /opt/aider/bin/aider --no-check-update --config /root/.aider-config/.aider.conf.yml
}
