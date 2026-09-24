#!/bin/bash
# ==============================================================================
# AI-CODER-ASSET.SH | Shared Helpers for Bootstrapped Binaries (gum, jq)
# Locating, resolving and downloading the helper binaries kept in .assets/.
# Sourced by ai-coder-gum.sh and ai-coder-jq.sh, which are themselves sourced
# standalone (ai-status.sh, offline/bundle.sh, ai-coder-status-common.sh), so
# this file is self-contained too: BASH_SOURCE-relative paths only, and
# functions from the full launch chain are used only when already defined.
# None of these toggle set -e — they are called both with and without it.
# ==============================================================================

# Absolute path of the project's .assets directory.
_asset_dir() {
    printf '%s/../.assets' "$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
}

# The binary name for the current platform: <base>.exe on Git Bash, else <base>.
_asset_exe_name() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        printf '%s.exe' "$1"
    else
        printf '%s' "$1"
    fi
}

# Release platform/arch of the current machine, as gum/jq name them.
_asset_host_platform() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then echo "Windows"; else echo "Linux"; fi
}
_asset_host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo "arm64" ;;
        *)             echo "x86_64" ;;
    esac
}

# True when <dir> holds a file named exactly <name>. A plain [ -f ] won't do
# on Git Bash, where "gum" also matches gum.exe — which made offline/bundle.sh
# skip the Linux build whenever the Windows one was already cached.
_asset_present() {
    [ -n "$(find "$1" -maxdepth 1 -type f -name "$2" 2>/dev/null)" ]
}

# Print the usable <base> binary: PATH first, then the current platform's
# .assets copy (both platforms' builds may be there: Git Bash can't run the
# Linux ELF, and WSL/Linux shouldn't use the .exe). Returns 1 if neither.
_asset_resolve() {
    local base="$1" local_bin
    if command -v "$base" &>/dev/null; then
        printf '%s' "$base"
        return 0
    fi
    local_bin="$(_asset_dir)/$(_asset_exe_name "$base")"
    [ -f "$local_bin" ] || return 1
    printf '%s' "$local_bin"
}

# Proxy URL for downloads: the stored proxy setting (read with whatever jq is
# already resolvable), else the standard proxy env vars. Empty when none.
_asset_proxy_url() {
    local proxy="" jq_bin
    if jq_bin=$(_asset_resolve jq); then
        # Via stdin: under MSYS_NO_PATHCONV a Windows jq.exe can't open /d/... paths.
        proxy=$("$jq_bin" -r '(.proxy // empty)' < "$(dirname "${BASH_SOURCE[0]}")/../user/settings.json" 2>/dev/null || true)
    fi
    [ -z "$proxy" ] && proxy=${HTTPS_PROXY:-${HTTP_PROXY:-${https_proxy:-${http_proxy:-}}}}
    [ -z "$proxy" ] && return 0
    proxy="${proxy/#https:\/\//http://}"
    # resolve_proxy_to_ip (ai-coder-env.sh) exists only in the full launch chain.
    if declare -f resolve_proxy_to_ip >/dev/null 2>&1; then
        resolve_proxy_to_ip "$proxy"
    else
        printf '%s' "$proxy"
    fi
}

# curl through the download proxy, if one is configured.
_asset_curl() {
    local proxy; proxy=$(_asset_proxy_url)
    if [ -n "$proxy" ]; then
        curl -x "$proxy" "$@"
    else
        curl "$@"
    fi
}

# Print the download URL of the first asset in <repo>'s latest GitHub release
# whose URL contains every <term> (case-insensitive) and doesn't match
# <exclude-regex>. Falls back to <fallback-url> when the API is unreachable
# (e.g. proxy-blocked) or nothing matches.
# Usage: _asset_release_url <owner/repo> <fallback-url> <exclude-regex> <term>...
_asset_release_url() {
    local repo="$1" fallback="$2" exclude="$3"; shift 3
    local urls term
    urls=$(_asset_curl -sL --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep "browser_download_url" | cut -d'"' -f4 || true)
    for term in "$@"; do
        urls=$(printf '%s\n' "$urls" | grep -iF -- "$term" || true)
    done
    local url; url=$(printf '%s\n' "$urls" | grep -viE -- "$exclude" | head -n1 || true)
    if [ -z "$url" ]; then
        echo "⚠ Proxy block detected or no match. Falling back to hardcoded URL for ${repo##*/}..." >&2
        url="$fallback"
    fi
    printf '%s' "$url"
}

# Download <url> to <dest> via <dest>.part, so an interrupted or failed
# download (including an HTTP error page) never leaves a truncated file
# under the final name for a later _asset_resolve to pick up.
_asset_fetch() {
    local url="$1" dest="$2"
    echo " Downloading asset from: $url"
    if _asset_curl -fsL --max-time 15 "$url" -o "$dest.part"; then
        mv -f "$dest.part" "$dest"
    else
        rm -f "$dest.part"
        return 1
    fi
}
