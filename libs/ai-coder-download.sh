#!/bin/bash
# ==============================================================================
# AI-CODER-DOWNLOAD.SH | Model Downloads & Build-Time Proxy Helpers
# Fetches the selected GGUF tier and the speculative-decoding draft
# (download_model / download_draft_model: .part file, sha256 check, rename),
# and renders the proxy-aware npm/pip commands the workbench image builds use.
# Sourced by ai-coder-core.sh — not run standalone.
# ==============================================================================

# Verify a file's sha256 against an expected value. No-op when the expected
# value is empty or sha256sum is unavailable. Removes the file on mismatch.
_verify_sha256() {
    local file="$1" expected="$2"
    [ -n "$expected" ] || return 0
    command -v sha256sum >/dev/null 2>&1 || return 0
    echo -e "${ICON_GEAR} Verifying checksum..."
    local actual; actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        rm -f "$file"
        echo -e "${RED}✘ Checksum mismatch — expected ${expected}, got ${actual}${NC}"
        echo -e "${YELLOW}  The download may be corrupt or tampered with. Please retry.${NC}"
        return 1
    fi
    echo -e "${GREEN}✔ Checksum verified${NC}"
}

# Download a URL to a local path. Selects the best available tool and handles proxy.
_download_file() {
    local url="$1" dest="$2"
    local win_curl=""
    [ "$IS_WSL" = "true" ] && win_curl=$(command -v curl.exe 2>/dev/null || true)
    local http_proxy=""
    [ -n "${DOWNLOAD_PROXY:-}" ] && http_proxy=$(resolve_proxy_to_ip "$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')")

    if [ "$IS_GITBASH" = "true" ] && command -v powershell.exe >/dev/null 2>&1; then
        local win_out; win_out=$(cygpath -w "$dest")
        local ps_cmd="\$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '${url}' -OutFile '${win_out}' -UseBasicParsing"
        [ -n "$http_proxy" ] && ps_cmd+=" -Proxy '${http_proxy}'"
        powershell.exe -NoProfile -NonInteractive -Command "$ps_cmd" &
        _await_download $! "$dest"
    elif [ -n "$http_proxy" ] && [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$dest")
        "$win_curl" -L --proxy "$http_proxy" --ssl-no-revoke --no-progress-meter --show-error -o "$win_path" "$url" &
        _await_download $! "$dest"
    elif [ -n "$http_proxy" ] && command -v curl >/dev/null 2>&1; then
        curl -L --proxy "$http_proxy" --progress-bar --show-error -o "$dest" "$url"
    elif [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$dest")
        "$win_curl" -L --no-progress-meter --show-error -o "$win_path" "$url" &
        _await_download $! "$dest"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar --show-error -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "$http_proxy" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$http_proxy" -e "https_proxy=$http_proxy")
        wget --no-verbose --show-progress --progress=dot:giga "${wget_proxy_args[@]}" -O "$dest" "$url"
    else
        return 1
    fi
}

# Pre-ed117a6 installs stored every model flat under $MODEL_STORAGE_DIR (no
# per-family subfolder). If the family's expected per-family path is missing
# but the old flat-named file is still on disk, move it into place instead of
# silently re-downloading a multi-GB file.
_migrate_flat_model_file() {
    local dest="$1"
    [ -f "$dest" ] && return 0
    local flat="$MODEL_STORAGE_DIR/$(basename "$dest")"
    [ "$flat" != "$dest" ] && [ -f "$flat" ] || return 0
    mkdir -p "$(dirname "$dest")"
    mv "$flat" "$dest"
    echo -e "${ICON_GEAR} Migrated existing download into per-family folder: $(basename "$dest")"
}

# Download the family's speculative-decoding draft model if missing.
download_draft_model() {
    local dest="$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE"
    _migrate_flat_model_file "$dest"
    [ -f "$dest" ] && return 0
    [ -n "${MODEL_DRAFT_URL:-}" ] || return 1
    mkdir -p "$(dirname "$dest")"
    local part="${dest}.part"
    rm -f "$part"
    echo -e "${ICON_GEAR} Downloading draft model ${CYAN}${MODEL_DRAFT_FILE}${NC} ${DIM}(speculative decoding)...${NC}"
    if _download_file "$MODEL_DRAFT_URL" "$part"; then
        _verify_sha256 "$part" "${MODEL_DRAFT_SHA256:-}" || return 1
        mv "$part" "$dest"
    else
        rm -f "$part"
        return 1
    fi
}

# Show a file-size progress ticker for a background download PID, then wait for it.
# Cleans up a partial file if the download fails.
_await_download() {
    local dl_pid="$1" file_path="$2"
    while kill -0 "$dl_pid" 2>/dev/null; do
        local sz; sz=$(stat -c%s "$file_path" 2>/dev/null || echo 0)
        printf "\r  Downloaded: %-12s" "$(_human_size "$sz")"
        sleep 2
    done
    printf "\n"
    if ! wait "$dl_pid"; then
        rm -f "$file_path"
        return 1
    fi
}

# Ensure the selected model is on disk: migrate a legacy flat-named copy
# into its per-family path if present, resolve the tier selection when
# MODEL_FILE isn't set yet, then download to a .part file (verify sha256,
# rename into place).
download_model() {
    if engine_is_sglang; then
        download_sglang_model
        return
    fi
    if [ -n "${MODEL_FILE:-}" ]; then
        local _new_path="$MODEL_STORAGE_DIR/$MODEL_FILE"
        _migrate_flat_model_file "$_new_path"
        [ -f "$_new_path" ] && return 0
    fi

    # Resolve model selection and metadata (file, url, sha256, desc) when not
    # already set — e.g. on the initial run or when MODEL_FILE was cleared.
    if [ -z "${MODEL_FILE:-}" ] || [ -z "${MODEL_URL:-}" ]; then
        select_model_for_vram "${EFFECTIVE_VRAM_GB:-${VRAM_GB:-0}}"
    fi

    local model_url="${MODEL_URL:-}"
    local model_hint="${MODEL_TIER:-$MODEL_FILE}"
    local model_sha="${MODEL_SHA256:-}"

    [ -z "$model_url" ] && { echo -e "${RED}✘ Missing download URL for $MODEL_FILE${NC}"; return 1; }

    local model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"
    local part_path="${model_path}.part"
    mkdir -p "$(dirname "$model_path")"

    # Remove any leftover partial download from a previous interrupted attempt.
    if [ -f "$part_path" ]; then
        echo -e "${YELLOW}⚠ Removing incomplete previous download: $(basename "$part_path")${NC}"
        rm -f "$part_path"
    fi

    echo -e "${ICON_GEAR} Downloading ${model_hint}..."
    echo -e "${CYAN}Downloading to: $model_path${NC}"
    [ -n "${DOWNLOAD_PROXY:-}" ] && echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"

    # Download to a .part file so an interrupted transfer never leaves a file
    # that looks like a complete model.
    if _download_file "$model_url" "$part_path"; then
        # Verify checksum when the family conf provides one (MODEL_<tier>_SHA256).
        _verify_sha256 "$part_path" "${model_sha:-}" || return 1
        mv "$part_path" "$model_path"
        echo -e "${GREEN}✔ Model downloaded successfully${NC}"
    else
        rm -f "$part_path"
        echo -e "${RED}✘ Download failed${NC}"
        return 1
    fi
}

# Resolve DOWNLOAD_PROXY to a plain http://ip:port URL for tools (npm, pip)
# that need an explicit http:// proxy scheme regardless of the configured
# scheme. resolve_proxy_to_ip converts the hostname to an IP so proxy
# resolution doesn't depend on DNS being reachable during a Docker build.
# Echoes empty when no proxy is configured. Shared by make_npm_proxy_cmds,
# make_pip_proxy_cmds, and any agent build_image() that installs via pip
# outside build_pip_install_cmds (e.g. Aider's venv-based install).
resolve_http_proxy_url() {
    [ -z "${DOWNLOAD_PROXY:-}" ] && return
    local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
    echo "$build_proxy" | sed 's|^https://|http://|'
}

# Returns Dockerfile RUN commands to configure npm proxy, or empty string if no proxy.
make_npm_proxy_cmds() {
    local npm_proxy; npm_proxy=$(resolve_http_proxy_url)
    [ -z "$npm_proxy" ] && return
    echo "RUN npm config set proxy $npm_proxy && npm config set https-proxy $npm_proxy && npm config set strict-ssl false"
}

make_pip_proxy_cmds() {
    # Returns the full command prefix to place between "RUN " and the package names.
    # When no proxy is configured: just "pip3 install --break-system-packages".
    # --break-system-packages is required on Debian Bookworm (PEP 668) to allow
    # system-wide pip installs inside Docker containers.
    # When proxy is configured: unset proxy env vars first (urllib3/pip tries
    # TLS-in-TLS when https_proxy is set, even with http:// scheme, causing
    # "check_hostname requires server_hostname"). Clearing the env vars and
    # passing --proxy http:// explicitly forces a plain CONNECT tunnel.
    local pip_proxy; pip_proxy=$(resolve_http_proxy_url)
    if [ -z "$pip_proxy" ]; then
        echo "pip3 install --break-system-packages"
        return
    fi
    echo "env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY pip3 install --break-system-packages --proxy $pip_proxy --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org"
}

build_pip_install_cmds() {
    # Usage: build_pip_install_cmds <pip_proxy_cmds> <offline_pkgs> <online_pkgs>
    # Returns Dockerfile RUN lines for offline pip packages (required) and online
    # pip packages (best-effort, || true). Used by agent build_image() functions.
    #
    # Pins mcp<2.0.0: the MCP Python SDK's 2.0.0 release removed the
    # @server.list_tools() decorator API that third-party servers like
    # mcp-server-git and cli-mcp-server are still built against, so an
    # unpinned install resolves 2.0.0 and they crash on startup with
    # "AttributeError: 'Server' object has no attribute 'list_tools'".
    # Remove this pin once those packages catch up to the new SDK.
    local pip_proxy_cmds="$1" mcp_pip_pkgs="$2" mcp_pip_online="$3"
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs} 'mcp<2.0.0'"
    fi
    if [ -n "$(echo "$mcp_pip_online" | tr -d ' ')" ]; then
        pip_cmd+=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_online} 'mcp<2.0.0' || true"
    fi
    printf '%s' "$pip_cmd"
}
