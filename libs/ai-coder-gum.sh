#!/bin/bash
# ==============================================================================
# AI-CODER-GUM.SH | Gum Binary Bootstrap & Resolution
# Downloads charmbracelet/gum on first use (no system package manager
# dependency) and resolves the active binary for callers. Deliberately
# self-contained — sourced by the full ai-coder launch chain as well as
# directly by ai-status.sh, offline/bundle.sh, and ai-coder-ui.sh (itself
# sourced standalone by offline/unbundle.sh), so it must not assume
# core.sh/env.sh globals beyond what's already resolved via
# BASH_SOURCE-relative paths.
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-asset.sh"

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
    _asset_present "$_gum_dir" "$gum_exe_name" && return 0

    # Windows builds are only published for x86_64 — gum_arch (which can be
    # arm64) only matters for the Linux search/fallback below.
    local search_arch="$gum_arch"
    [ "$platform" = "Windows" ] && search_arch="x86_64"

    local download_url
    download_url=$(_asset_release_url charmbracelet/gum \
        "https://github.com/charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_${platform}_${search_arch}${ext}" \
        'sbom|\.sig|\.pem' "${platform}_${search_arch}" "$ext")

    # Download and extract in a scratch dir, then move only the binary into
    # place, so a failed run never leaves a partial gum behind. tar runs from
    # inside the work dir: GNU tar reads a "C:/..." archive path as host:path.
    local _work="$_gum_dir/.gum-download"
    rm -rf "$_work"; mkdir -p "$_work"
    local archive="$_work/gum$ext"
    if _asset_fetch "$download_url" "$archive"; then
        if [ "$ext" = ".zip" ]; then
            if command -v unzip >/dev/null 2>&1; then
                unzip -o "$archive" -d "$_work" &>/dev/null || true
            elif command -v tar >/dev/null 2>&1; then
                (cd "$_work" && tar -xf "gum$ext") &>/dev/null || true
            else
                local _py="import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])"
                python3 -c "$_py" "$archive" "$_work" 2>/dev/null || \
                    python -c "$_py" "$archive" "$_work" 2>/dev/null || true
            fi
        else
            (cd "$_work" && tar -xzf "gum$ext") &>/dev/null || true
        fi
        local _bin; _bin=$(find "$_work" -type f -name "$gum_exe_name" 2>/dev/null | head -n1 || true)
        [ -n "$_bin" ] && mv -f "$_bin" "$_gum_dir/$gum_exe_name"
    fi
    rm -rf "$_work"

    _asset_present "$_gum_dir" "$gum_exe_name" || return 1
    chmod +x "$_gum_dir/$gum_exe_name" 2>/dev/null || return 1
}

# ------------------------------------------------------------------------------
# ensure_gum — download and install charmbracelet/gum if unavailable
#
# On first call downloads gum from GitHub releases into ./.assets. If gum is
# already on PATH or installed in that directory, returns immediately.
# ------------------------------------------------------------------------------
ensure_gum() {
    echo -ne "⚡ Checking for interface engine (gum)... "
    command -v gum &>/dev/null && { echo "found in PATH"; return 0; }
    _asset_resolve gum >/dev/null && { echo "found locally"; return 0; }
    echo "not found."

    echo "⚡ Bootstrapping status interface engine..."
    if _download_gum_binary "$(_asset_host_platform)" "$(_asset_host_arch)" "$(_asset_dir)"; then
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
    local _gum; _gum=$(_asset_resolve gum) || return 1
    GUM_CMD="$_gum"
}
