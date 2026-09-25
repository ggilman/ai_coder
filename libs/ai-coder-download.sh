#!/bin/bash
# ==============================================================================
# AI-CODER-DOWNLOAD.SH | Model Downloads & Build-Time Proxy Helpers
# Fetches the selected GGUF tier and the speculative-decoding draft
# (download_model / download_draft_model: per-file lock, disk-space check,
# resumable .part file with retries, sha256/GGUF check, rename),
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

# Resolve the curl downloads use into DL_CURL, and DL_CURL_WIN=true when it
# is a native Windows binary that needs Windows paths. Prefers Windows' own
# curl.exe (Schannel, so the Windows cert store — which is what makes
# TLS-inspecting corporate proxies work): via interop on WSL, from System32 on
# Git Bash. Git Bash's bundled curl is a native Windows program too, so it
# also gets Windows paths (MSYS_NO_PATHCONV=1 stops MSYS converting them).
# DL_CURL is empty when no curl is available (wget fallback).
_resolve_download_curl() {
    DL_CURL="" DL_CURL_WIN=false
    if [ "$IS_GITBASH" = "true" ]; then
        local sys; sys="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32/curl.exe"
        if [ -f "$sys" ]; then DL_CURL="$sys"; else DL_CURL=$(command -v curl 2>/dev/null || true); fi
        [ -n "$DL_CURL" ] && DL_CURL_WIN=true
        return 0
    fi
    if [ "$IS_WSL" = "true" ]; then
        DL_CURL=$(command -v curl.exe 2>/dev/null || true)
        [ -n "$DL_CURL" ] && { DL_CURL_WIN=true; return 0; }
    fi
    DL_CURL=$(command -v curl 2>/dev/null || true)
}

# Host path -> the form DL_CURL needs for -o.
_dl_path() {
    if ! $DL_CURL_WIN; then echo "$1"
    elif [ "$IS_GITBASH" = "true" ]; then cygpath -w "$1"
    else wslpath -w "$1"
    fi
}

# DOWNLOAD_PROXY as a plain http://ip:port for curl/wget, or empty.
_dl_proxy() {
    [ -n "${DOWNLOAD_PROXY:-}" ] || return 0
    resolve_proxy_to_ip "$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')"
}

# Download a URL to a local path, resuming whatever is already in <dest>.
# A transfer that stays under 1 KB/s for 60s (a connection that hung without
# closing — common behind proxies) is aborted as a failure (curl exit 28), so
# the retry wrapper resumes it instead of waiting forever. Resuming a file
# that is already complete is not an error (curl ignores the 416 then).
_download_file() {
    local url="$1" dest="$2"
    local http_proxy; http_proxy=$(_dl_proxy)
    _resolve_download_curl

    if [ -n "$DL_CURL" ]; then
        local args=(-fL -C - --connect-timeout 30 --speed-limit 1024 --speed-time 60 --show-error)
        [ -n "$http_proxy" ] && args+=(--proxy "$http_proxy")
        if $DL_CURL_WIN; then
            [ -n "$http_proxy" ] && args+=(--ssl-no-revoke)
            # Windows curl's own progress meter doesn't render through the
            # interop console, so show a size ticker instead.
            "$DL_CURL" "${args[@]}" --no-progress-meter -o "$(_dl_path "$dest")" "$url" &
            _await_download $! "$dest"
        else
            "$DL_CURL" "${args[@]}" --progress-bar -o "$dest" "$url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "$http_proxy" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$http_proxy" -e "https_proxy=$http_proxy")
        wget -c --read-timeout=60 --tries=1 --no-verbose --show-progress --progress=dot:giga \
            "${wget_proxy_args[@]}" -O "$dest" "$url"
    else
        echo -e "${RED}✘ Neither curl nor wget is available to download with${NC}"
        return 1
    fi
}

# One download attempt for _download_file_with_retry. The partial file is
# kept for the next attempt to resume, except when the server can't resume
# it (curl 33: no byte-range support; 36: bad resume offset) — then it is
# dropped so the next attempt starts over.
_download_attempt() {
    local rc=0
    _download_file "$1" "$2" || rc=$?
    if [ "$rc" -eq 33 ] || [ "$rc" -eq 36 ]; then
        echo -e "${YELLOW}⚠ Server can't resume this download — restarting it from the beginning.${NC}"
        rm -f "$2"
    fi
    return "$rc"
}

# Retry wrapper around _download_file for transient network failures, each
# attempt resuming the last one's partial file. AI_CODER_DOWNLOAD_RETRIES
# overrides the total attempt count (default 3). A checksum mismatch is NOT
# retried — it's a corrupt/tamper signal, not a network blip (see _verify_download).
_download_file_with_retry() {
    retry_with_backoff "${AI_CODER_DOWNLOAD_RETRIES:-3}" "Download" _download_attempt "$1" "$2"
}

# HEAD <url> (following redirects) and set DL_REMOTE_SIZE (bytes) and
# DL_REMOTE_SHA256 (Hugging Face's X-Linked-Etag, which is the file's sha256
# for LFS-stored files like GGUFs), each empty when unavailable. Best-effort:
# any failure (offline, proxy, no curl) just leaves both empty.
_probe_remote_file() {
    DL_REMOTE_SIZE="" DL_REMOTE_SHA256=""
    _resolve_download_curl
    [ -n "$DL_CURL" ] || return 0
    local http_proxy; http_proxy=$(_dl_proxy)
    local args=(-sSIL --connect-timeout 15 --max-time 30)
    [ -n "$http_proxy" ] && args+=(--proxy "$http_proxy")
    $DL_CURL_WIN && [ -n "$http_proxy" ] && args+=(--ssl-no-revoke)
    local headers
    headers=$("$DL_CURL" "${args[@]}" "$1" 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z') || return 0
    # The redirect hop carries x-linked-size/-etag; the final hop's
    # content-length is the file itself.
    DL_REMOTE_SIZE=$(printf '%s\n' "$headers" | awk -F': *' '$1=="x-linked-size"{v=$2} END{print v}')
    [ -n "$DL_REMOTE_SIZE" ] || DL_REMOTE_SIZE=$(printf '%s\n' "$headers" | awk -F': *' '$1=="content-length"{v=$2} END{print v}')
    { [[ "$DL_REMOTE_SIZE" =~ ^[0-9]+$ ]] && [ "$DL_REMOTE_SIZE" -gt 0 ]; } || DL_REMOTE_SIZE=""
    local etag; etag=$(printf '%s\n' "$headers" | awk -F': *' '$1=="x-linked-etag"{v=$2} END{print v}' | tr -d '"')
    etag="${etag#w/}"
    [[ "$etag" =~ ^[0-9a-f]{64}$ ]] && DL_REMOTE_SHA256="$etag"
    return 0
}

# Fail early when <dir>'s filesystem can't hold the rest of a <total>-byte
# download whose .part already has <have> bytes. Skipped when the size is
# unknown or df can't tell.
_check_disk_space() {
    local dir="$1" total="$2" have="${3:-0}"
    [ -n "$total" ] || return 0
    local avail_kb; avail_kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 0
    local need=$(( total - have )) avail=$(( avail_kb * 1024 ))
    [ "$need" -gt 0 ] || return 0
    if [ "$need" -gt "$avail" ]; then
        echo -e "${RED}✘ Not enough disk space: need $(_human_size "$need"), only $(_human_size "$avail") free in ${dir}${NC}"
        echo -e "${YELLOW}  Free up space there, or point the model storage somewhere with more room.${NC}"
        return 1
    fi
}

# Check a finished download before it's renamed into place: sha256 against
# the family conf's value, else Hugging Face's (see _probe_remote_file), and
# the GGUF magic bytes (catches an HTML error page or a truncated header even
# when no checksum is known). Removes the file on failure.
_verify_download() {
    local file="$1" sha="$2"
    if [ -z "$sha" ] && [ -n "${DL_REMOTE_SHA256:-}" ]; then
        sha="$DL_REMOTE_SHA256"
        echo -e "${DIM}  (no checksum in the family conf — using Hugging Face's)${NC}"
    fi
    _verify_sha256 "$file" "$sha" || return 1
    if [[ "$file" == *.gguf.part ]] && [ "$(head -c 4 "$file" 2>/dev/null)" != "GGUF" ]; then
        rm -f "$file"
        echo -e "${RED}✘ Downloaded file is not a GGUF model (bad header) — removed it. Please retry.${NC}"
        return 1
    fi
}

# Download <url> to <dest> via <dest>.part, resuming a partial left by an
# earlier attempt or launch, then verify and rename. Assumes the caller holds
# the file's download lock. <label> is shown in the progress messages.
_fetch_model_file() {
    local url="$1" dest="$2" sha="$3" label="$4"
    local part="${dest}.part"
    mkdir -p "$(dirname "$dest")"

    _probe_remote_file "$url"
    local have=0
    [ -f "$part" ] && have=$(stat -c%s "$part" 2>/dev/null || echo 0)
    _check_disk_space "$(dirname "$dest")" "$DL_REMOTE_SIZE" "$have" || return 1

    if [ "$have" -gt 0 ]; then
        echo -e "${ICON_GEAR} Resuming ${label} ${DIM}($(_human_size "$have")${DL_REMOTE_SIZE:+ of $(_human_size "$DL_REMOTE_SIZE")} already downloaded)${NC}..."
    else
        echo -e "${ICON_GEAR} Downloading ${label}${DL_REMOTE_SIZE:+ ${DIM}($(_human_size "$DL_REMOTE_SIZE"))${NC}}..."
    fi
    echo -e "${CYAN}Downloading to: $dest${NC}"
    [ -n "${DOWNLOAD_PROXY:-}" ] && echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"

    # The .part file means an interrupted transfer never leaves a file that
    # looks like a complete model — and is what the next attempt resumes.
    if ! _download_file_with_retry "$url" "$part"; then
        echo -e "${RED}✘ Download failed${NC}"
        [ -s "$part" ] && echo -e "${DIM}  Partial download kept in $(basename "$part") — the next launch resumes it.${NC}"
        return 1
    fi
    _verify_download "$part" "$sha" || return 1
    mv "$part" "$dest"
}

# Run <cmd...> holding the download lock for <dest> (<dest>.lock), so a
# second session launched mid-download waits for the first instead of
# deleting or rewriting its partial file — then finds the file done. The
# lock path is kept in DOWNLOAD_LOCK_DIR so ai-coder's cleanup trap can
# release it after a Ctrl-C.
_with_download_lock() {
    local dest="$1"; shift
    local lock="${dest}.lock"
    mkdir -p "$(dirname "$dest")"
    acquire_lock "$lock" 2 60 "Another ai-coder session is downloading $(basename "$dest") — waiting for it..."
    DOWNLOAD_LOCK_DIR="$lock"
    local rc=0
    "$@" || rc=$?
    release_lock "$lock"
    DOWNLOAD_LOCK_DIR=""
    return "$rc"
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
    _with_download_lock "$dest" _download_draft_locked "$dest"
}

_download_draft_locked() {
    local dest="$1"
    [ -f "$dest" ] && return 0   # finished by the session we waited for
    _fetch_model_file "$MODEL_DRAFT_URL" "$dest" "${MODEL_DRAFT_SHA256:-}" \
        "draft model ${CYAN}${MODEL_DRAFT_FILE}${NC} ${DIM}(speculative decoding)${NC}"
}

# Show a file-size progress ticker for a background download PID, then wait
# for it and return its exit status. The partial file is left for a resume.
_await_download() {
    local dl_pid="$1" file_path="$2"
    while kill -0 "$dl_pid" 2>/dev/null; do
        local sz; sz=$(stat -c%s "$file_path" 2>/dev/null || echo 0)
        printf "\r  Downloaded: %-12s" "$(_human_size "$sz")"
        sleep 2
    done
    printf "\n"
    local rc=0
    wait "$dl_pid" || rc=$?
    return "$rc"
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

    [ -z "${MODEL_URL:-}" ] && { echo -e "${RED}✘ Missing download URL for $MODEL_FILE${NC}"; return 1; }
    _with_download_lock "$MODEL_STORAGE_DIR/$MODEL_FILE" _download_model_locked
}

_download_model_locked() {
    local model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"
    [ -f "$model_path" ] && return 0   # finished by the session we waited for
    # sha256 from the family conf (MODEL_<tier>_SHA256), else Hugging Face's.
    _fetch_model_file "$MODEL_URL" "$model_path" "${MODEL_SHA256:-}" "${MODEL_TIER:-$MODEL_FILE}" || return 1
    echo -e "${GREEN}✔ Model downloaded successfully${NC}"
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
