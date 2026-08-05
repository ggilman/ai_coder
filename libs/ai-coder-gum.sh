#!/bin/bash
# ==============================================================================
# AI-CODER-GUM.SH | Gum Binary Bootstrap & Resolution
# Downloads charmbracelet/gum on first use (no system package manager
# dependency) and resolves the active binary for callers. Deliberately
# self-contained — sourced standalone by ai-status.sh in addition to the full
# ai-coder launch chain, so it must not assume core.sh/env.sh globals beyond
# what's already resolved via BASH_SOURCE-relative paths.
# ==============================================================================

# ------------------------------------------------------------------------------
# _download_gum_binary — download+extract a specific gum platform build
#
# Usage: _download_gum_binary <platform:Windows|Linux> <arch:x86_64|arm64> <dest_dir>
# Skips the download if dest_dir already has the binary (cache hit). Used both
# by ensure_gum (current-platform bootstrap) and offline/bundle.sh (which
# fetches both platform builds to ship inside the air-gapped bundle).
# Returns 0 with the binary present at dest_dir, 1 if download/extract failed.
# ------------------------------------------------------------------------------
_download_gum_binary() {
    local platform="$1" gum_arch="$2" _gum_dir="$3"
    local gum_exe_name="gum" ext=".tar.gz"
    if [ "$platform" = "Windows" ]; then
        gum_exe_name="gum.exe"
        ext=".zip"
    fi

    mkdir -p "$_gum_dir"
    [ -f "$_gum_dir/$gum_exe_name" ] && return 0

    set +e
    local _proxy_opt=""
    # Use grep to fetch the proxy manually to avoid dependency on functions defined later
    local _cur_proxy
    _cur_proxy=$(grep "^proxy=" "$(dirname "${BASH_SOURCE[0]}")/../user/settings.conf" 2>/dev/null | cut -d= -f2- || true)
    # Also check if HTTP_PROXY/HTTPS_PROXY environment variables are set
    [ -z "$_cur_proxy" ] && _cur_proxy=${HTTPS_PROXY:-${HTTP_PROXY:-${https_proxy:-${http_proxy:-}}}}
    # Ensure we use -x for curl proxy. resolve_proxy_to_ip (ai-coder-env.sh) is
    # only available via the full launch chain; this file is also sourced
    # standalone (see header), so fall back to the raw proxy URL when it's
    # not defined rather than erroring on an undefined function.
    if [ -n "$_cur_proxy" ]; then
        local _proxy_normalized; _proxy_normalized=$(echo "$_cur_proxy" | sed 's|^https://|http://|')
        if declare -f resolve_proxy_to_ip >/dev/null 2>&1; then
            _proxy_opt="-x $(resolve_proxy_to_ip "$_proxy_normalized")"
        else
            _proxy_opt="-x $_proxy_normalized"
        fi
    fi

    # Windows builds are only published for x86_64 — gum_arch (which can be
    # arm64) only matters for the Linux search/fallback below.
    local search_arch="$gum_arch"
    [ "$platform" = "Windows" ] && search_arch="x86_64"

    local download_url
    download_url=$(curl -sL $_proxy_opt --max-time 15 \
        "https://api.github.com/repos/charmbracelet/gum/releases/latest" \
        | grep "browser_download_url" \
        | grep -i "${platform}_${search_arch}" \
        | grep -i "${ext}" \
        | grep -v "sbom" \
        | grep -v ".sig" \
        | grep -v ".pem" \
        | cut -d'"' -f4 | head -n1 || true)

    if [ -z "$download_url" ]; then
        echo "⚠ Proxy block detected or no match. Falling back to hardcoded URL for Gum..."
        download_url="https://github.com/charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_${platform}_${search_arch}${ext}"
    fi

    echo " Downloading asset from: $download_url"
    if [ "$platform" = "Windows" ]; then
        curl -sL $_proxy_opt --max-time 15 "$download_url" -o "$_gum_dir/gum.zip"
        if command -v unzip >/dev/null 2>&1; then
            unzip -o "$_gum_dir/gum.zip" -d "$_gum_dir" &>/dev/null
        elif command -v tar >/dev/null 2>&1; then
            tar -xf "$_gum_dir/gum.zip" -C "$_gum_dir" &>/dev/null
        else
            python3 -c "import zipfile; zipfile.ZipFile('$_gum_dir/gum.zip', 'r').extractall('$_gum_dir')" 2>/dev/null || \
            python -c "import zipfile; zipfile.ZipFile('$_gum_dir/gum.zip', 'r').extractall('$_gum_dir')" 2>/dev/null
        fi
        [ -d "$_gum_dir/gum_0.17.0_Windows_x86_64" ] && mv "$_gum_dir/gum_0.17.0_Windows_x86_64/gum.exe" "$_gum_dir/gum.exe" 2>/dev/null
        [ -d "$_gum_dir/gum_0.14.3_Windows_x86_64" ] && mv "$_gum_dir/gum_0.14.3_Windows_x86_64/gum.exe" "$_gum_dir/gum.exe" 2>/dev/null
        [ -f "$_gum_dir/gum.exe" ] || find "$_gum_dir" -name "gum.exe" -exec mv {} "$_gum_dir/gum.exe" \; 2>/dev/null
        rm -f "$_gum_dir/gum.zip"
        find "$_gum_dir" -maxdepth 1 -type d -name "gum_*" -exec rm -rf {} + 2>/dev/null
    else
        curl -sL $_proxy_opt --max-time 15 "$download_url" -o "$_gum_dir/gum.tar.gz"
        tar -xzf "$_gum_dir/gum.tar.gz" -C "$_gum_dir" &>/dev/null
        find "$_gum_dir" -type f -name "gum" -exec mv {} "$_gum_dir/" \; &>/dev/null
        rm -f "$_gum_dir/gum.tar.gz"
        find "$_gum_dir" -maxdepth 1 -type d -name "gum_*" -exec rm -rf {} + 2>/dev/null
    fi
    local dl_status=$?
    set -e

    if [ $dl_status -ne 0 ] || [ ! -f "$_gum_dir/$gum_exe_name" ]; then
        return 1
    fi

    chmod +x "$_gum_dir/$gum_exe_name" 2>/dev/null || return 1
    return 0
}

# ------------------------------------------------------------------------------
# ensure_gum — download and install charmbracelet/gum if unavailable
#
# On first call downloads gum from GitHub releases into ./.assets. If gum is
# already on PATH or installed in that directory, returns immediately.
# ------------------------------------------------------------------------------
ensure_gum() {
    local gum_exe_name="gum"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        gum_exe_name="gum.exe"
    fi

    local _gum_dir
    _gum_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)/../.assets"
    mkdir -p "$_gum_dir"

    echo -ne "⚡ Checking for interface engine (gum)... "
    command -v gum &>/dev/null && { echo "found in PATH"; return 0; }
    [ -f "$_gum_dir/$gum_exe_name" ] && { echo "found locally"; return 0; }
    echo "not found."

    echo "⚡ Bootstrapping status interface engine..."

    local arch; arch=$(uname -m)
    local gum_arch="x86_64"
    case "$arch" in
        x86_64|amd64) gum_arch="x86_64" ;;
        aarch64|arm64) gum_arch="arm64" ;;
    esac

    local platform="Linux"
    [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && platform="Windows"

    if _download_gum_binary "$platform" "$gum_arch" "$_gum_dir"; then
        echo "✅ Setup interface engine ready!"
    else
        echo "⚠ Failed to download gum — running without interface enhancements."
    fi
}

# ------------------------------------------------------------------------------
# resolve_gum_cmd — resolve the active gum binary into GUM_CMD
#
# Priority: PATH binary > installed binary (gum.exe preferred on Windows).
# Returns 0 on success, 1 if gum is not found anywhere.
# ------------------------------------------------------------------------------
resolve_gum_cmd() {
    local _gum_dir
    _gum_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)/../.assets"
    local gum_exe_name="gum"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        gum_exe_name="gum.exe"
    fi

    if command -v gum &> /dev/null; then
        GUM_CMD="gum"
        return 0
    fi

    if [ -f "$_gum_dir/$gum_exe_name" ]; then
        GUM_CMD="$_gum_dir/$gum_exe_name"
        return 0
    fi

    return 1
}
