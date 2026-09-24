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

source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-asset.sh"

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
    _asset_present "$_jq_dir" "$jq_exe_name" && return 0

    # Windows builds are only published for x86_64; Linux honors jq_arch
    # (which can be arm64).
    local asset_arch="amd64"
    [ "$platform" != "Windows" ] && [ "$jq_arch" = "arm64" ] && asset_arch="arm64"

    local asset_base="jq-${asset_os}-${asset_arch}"
    [ "$platform" = "Windows" ] && asset_base+=".exe"

    local download_url
    download_url=$(_asset_release_url jqlang/jq \
        "https://github.com/jqlang/jq/releases/download/jq-1.8.2/${asset_base}" \
        'sha256|sbom' "$asset_base")

    _asset_fetch "$download_url" "$_jq_dir/$jq_exe_name" || return 1
    chmod +x "$_jq_dir/$jq_exe_name" 2>/dev/null || return 1
}

# ------------------------------------------------------------------------------
# ensure_jq - download and install jq if unavailable
#
# On first call downloads jq from GitHub releases into ./.assets. If jq is
# already on PATH or installed in that directory, returns immediately.
# ------------------------------------------------------------------------------
ensure_jq() {
    # Silent when jq is already available (PATH or .assets); the bootstrap
    # message only appears when a download is actually needed, so it doesn't
    # add startup noise on machines that already have jq.
    _asset_resolve jq >/dev/null && return 0

    echo "⚡ Bootstrapping JSON engine (jq)..."
    if _download_jq_binary "$(_asset_host_platform)" "$(_asset_host_arch)" "$(_asset_dir)"; then
        echo "✅ JSON engine ready!"
    else
        echo "⚠ Failed to download jq - user settings will fall back to defaults."
    fi
}

# ------------------------------------------------------------------------------
# resolve_jq_cmd - resolve the active jq binary into JQ_CMD
#
# Priority: PATH binary > installed binary (jq.exe preferred on Windows).
# On Git Bash, JQ_CMD is the _jq_host_paths wrapper instead (see below).
# Returns 0 on success, 1 if jq is not found anywhere.
# ------------------------------------------------------------------------------
resolve_jq_cmd() {
    local _jq; _jq=$(_asset_resolve jq) || return 1
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        _JQ_BIN="$_jq"
        JQ_CMD="_jq_host_paths"
    else
        JQ_CMD="$_jq"
    fi
}

# Run jq with absolute file arguments converted to Windows form. The launch
# chain exports MSYS_NO_PATHCONV=1 (ai-coder-core.sh), so a Windows-native
# jq.exe would otherwise be handed /d/... paths it can't open — every
# settings read silently fell back to defaults on Git Bash.
_jq_host_paths() {
    local _a _args=()
    for _a in "$@"; do
        if [[ "$_a" == /* ]] && [ -e "$_a" ]; then
            _args+=("$(cygpath -m "$_a")")
        else
            _args+=("$_a")
        fi
    done
    "$_JQ_BIN" "${_args[@]}"
}
