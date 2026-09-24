#!/bin/bash
# ==============================================================================
# AI-CODER-JQ.SH | jq Binary Bootstrap & Resolution
# Downloads jq (JSON parser for the user settings/state files) on first use
# (no system package manager dependency) and resolves the active binary for
# callers. Deliberately self-contained - sourced by the full ai-coder launch
# chain as well as standalone by ai-coder-status-common.sh, so it must not
# assume core.sh/env.sh globals beyond what's already resolved via
# BASH_SOURCE-relative paths.
# ==============================================================================

# ------------------------------------------------------------------------------
# _download_jq_binary - download a specific jq platform build
#
# Usage: _download_jq_binary <platform:Windows|Linux> <arch:x86_64|arm64> <dest_dir>
# Skips the download if dest_dir already has the binary (cache hit). Used both
# by ensure_jq (current-platform bootstrap) and offline/bundle.sh (which
# fetches both platform builds to ship inside the air-gapped bundle).
# Returns 0 with the binary present at dest_dir, 1 if the download failed.
#
# Unlike gum (archived releases), jq publishes single plain binaries: the
# release assets are named jq-<os>-<arch> with Windows carrying a .exe suffix,
# and <arch> is amd64 (not x86_64) for 64-bit.
# ------------------------------------------------------------------------------
_download_jq_binary() {
    local platform="$1" jq_arch="$2" _jq_dir="$3"
    local jq_exe_name="jq" asset_os="linux"
    if [ "$platform" = "Windows" ]; then
        jq_exe_name="jq.exe"
        asset_os="windows"
    fi

    mkdir -p "$_jq_dir"
    [ -f "$_jq_dir/$jq_exe_name" ] && return 0

    set +e
    local _proxy_opt=""
    # Stored proxy, like _download_gum_binary: settings.json first (only when a
    # jq is already resolvable to read it with), else ONE-GENERATION legacy
    # flat grep of user/settings.conf (removable next release), else env.
    local _cur_proxy=""
    # Resolve a jq to read the stored proxy with: system binary first, then a
    # previously-downloaded .assets copy for the CURRENT platform (the one
    # being downloaded may be the other platform's, for offline/bundle.sh —
    # Git Bash can't run the Linux ELF). Bare `jq` alone would miss the
    # .assets-only case.
    local _jq_bin=""
    resolve_jq_cmd &>/dev/null && _jq_bin="$JQ_CMD"
    if [ -n "$_jq_bin" ]; then
        _cur_proxy=$("$_jq_bin" -r '(.proxy // empty)' "$(dirname "${BASH_SOURCE[0]}")/../user/settings.json" 2>/dev/null || true)
    fi
    [ -z "$_cur_proxy" ] && _cur_proxy=$(grep "^proxy=" "$(dirname "${BASH_SOURCE[0]}")/../user/settings.conf" 2>/dev/null | cut -d= -f2- || true)
    [ -z "$_cur_proxy" ] && _cur_proxy=${HTTPS_PROXY:-${HTTP_PROXY:-${https_proxy:-${http_proxy:-}}}}
    # resolve_proxy_to_ip (ai-coder-env.sh) is only available via the full
    # launch chain; this file is also sourced standalone (see header), so fall
    # back to the raw proxy URL when it's not defined rather than error.
    if [ -n "$_cur_proxy" ]; then
        local _proxy_normalized; _proxy_normalized=$(echo "$_cur_proxy" | sed 's|^https://|http://|')
        if declare -f resolve_proxy_to_ip >/dev/null 2>&1; then
            _proxy_opt="-x $(resolve_proxy_to_ip "$_proxy_normalized")"
        else
            _proxy_opt="-x $_proxy_normalized"
        fi
    fi

    # Windows builds are only published for x86_64; the Linux arm64 search
    # below still honors jq_arch (which can be arm64).
    local search_arch="$jq_arch"
    [ "$platform" = "Windows" ] && search_arch="x86_64"
    local asset_arch="amd64"
    [ "$search_arch" = "arm64" ] && asset_arch="arm64"

    local asset_base="jq-${asset_os}-${asset_arch}"
    [ "$platform" = "Windows" ] && asset_base+=".exe"

    local download_url
    download_url=$(curl -sL $_proxy_opt --max-time 15 \
        "https://api.github.com/repos/jqlang/jq/releases/latest" \
        | grep "browser_download_url" \
        | grep "${asset_base}" \
        | grep -v "sha256" \
        | grep -v "sbom" \
        | cut -d'"' -f4 | head -n1 || true)

    if [ -z "$download_url" ]; then
        echo "⚠ Proxy block detected or no match. Falling back to hardcoded URL for jq..."
        download_url="https://github.com/jqlang/jq/releases/download/jq-1.8.2/${asset_base}"
    fi

    echo " Downloading asset from: $download_url"
    local dl_status
    curl -sL $_proxy_opt --max-time 15 "$download_url" -o "$_jq_dir/$jq_exe_name"
    dl_status=$?
    set -e

    if [ $dl_status -ne 0 ] || [ ! -f "$_jq_dir/$jq_exe_name" ]; then
        return 1
    fi

    chmod +x "$_jq_dir/$jq_exe_name" 2>/dev/null || return 1
    return 0
}

# ------------------------------------------------------------------------------
# ensure_jq - download and install jq if unavailable
#
# On first call downloads jq from GitHub releases into ./.assets. If jq is
# already on PATH or installed in that directory, returns immediately.
# ------------------------------------------------------------------------------
ensure_jq() {
    local jq_exe_name="jq"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        jq_exe_name="jq.exe"
    fi

    local _jq_dir
    _jq_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)/../.assets"
    mkdir -p "$_jq_dir"

    # Silent when jq is already available (PATH or .assets); the bootstrap
    # message only appears when a download is actually needed, so it doesn't
    # add startup noise on machines that already have jq.
    command -v jq &>/dev/null && return 0
    [ -f "$_jq_dir/$jq_exe_name" ] && return 0

    echo "⚡ Bootstrapping JSON engine (jq)..."

    local arch; arch=$(uname -m)
    local jq_arch="x86_64"
    case "$arch" in
        x86_64|amd64) jq_arch="x86_64" ;;
        aarch64|arm64) jq_arch="arm64" ;;
    esac

    local platform="Linux"
    [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && platform="Windows"

    if _download_jq_binary "$platform" "$jq_arch" "$_jq_dir"; then
        echo "✅ JSON engine ready!"
    else
        echo "⚠ Failed to download jq - user settings will fall back to defaults."
    fi
}

# ------------------------------------------------------------------------------
# resolve_jq_cmd - resolve the active jq binary into JQ_CMD
#
# Priority: PATH binary > installed binary (jq.exe preferred on Windows).
# Returns 0 on success, 1 if jq is not found anywhere.
# ------------------------------------------------------------------------------
resolve_jq_cmd() {
    local _jq_dir
    _jq_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)/../.assets"
    local jq_exe_name="jq"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        jq_exe_name="jq.exe"
    fi

    if command -v jq &>/dev/null; then
        JQ_CMD="jq"
        return 0
    fi

    if [ -f "$_jq_dir/$jq_exe_name" ]; then
        JQ_CMD="$_jq_dir/$jq_exe_name"
        return 0
    fi

    return 1
}
