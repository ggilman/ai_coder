#!/bin/bash
# ==============================================================================
# AI-CODER-CORE.SH | Shared Infrastructure Library
# ==============================================================================
set -euo pipefail

# --- [ GLOBAL CONFIGURATION ] -------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
USER_DIR="$INSTALL_DIR/user"
SETTINGS_FILE="$USER_DIR/settings.conf"
STATE_FILE="$USER_DIR/state.conf"
PACKAGES_DIR="$INSTALL_DIR/packages"
DOCKER_BIN="${DOCKER_BIN:-}"
# Resolve the default Docker Desktop path, handling both Git Bash (/c/...) and
# backslash Windows paths (for WSL powershell.exe invocation).
if [ -z "$DOCKER_BIN" ]; then
    _docker_default_gb="/c/Program Files/Docker/Docker/Docker Desktop.exe"
    _docker_default_win="C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe"
    [ -f "$_docker_default_gb" ] && DOCKER_BIN="$_docker_default_gb" || DOCKER_BIN="$_docker_default_win"
fi
GLOBAL_ENGINE_NAME="ai-hub-engine"
GLOBAL_PROXY_NAME="ai-hub-proxy"
MODEL_VOLUME_NAME="ai-coder-models"
HUB_NETWORK="ai-engineering-net"
HUB_ISOLATED_NET="ai-engineering-isolated"
NETWORK_INTERNAL=false
NEEDS_LITELLM_PROXY=false
BUILD_ONLY=false
WORKBENCH_PREFIX="coder"
LITELLM_IMAGE="ghcr.io/berriai/litellm:main-latest"
LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
if [ -z "$DOWNLOAD_PROXY" ] && [ -f "$SETTINGS_FILE" ]; then
    DOWNLOAD_PROXY=$(grep '^proxy=' "$SETTINGS_FILE" 2>/dev/null | cut -d= -f2- || true)
fi
BASE_IMAGE="node:24-bookworm-slim"

# --- [ ENVIRONMENT & SHELL ] --------------------------------------------------
export MSYS_NO_PATHCONV=1
PROJECT_ID=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
WORKSPACE_DIR=$(basename "$PWD" | tr ' ' '_')

# Graphics (colors & icons)
source "$SCRIPT_DIR/ai-coder-graphics.sh"

# Model framework configuration — family-specific conf is sourced by ai-coder
# after the user's family preference is resolved.
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
source "$CONFIG_DIR/ai-coder-model.conf"

IS_WSL=$(grep -qi Microsoft /proc/version 2>/dev/null && echo "true" || echo "false")
IS_GITBASH=$(expr "$(uname -s)" : '.*MINGW.*' >/dev/null 2>&1 && echo "true" || echo "false")

# Fast model storage default: on Windows hosts (WSL/Git Bash) the engine's
# bind mount of the model folder goes through Docker Desktop's slow 9p bridge,
# so caching the model in a native Docker volume is a big load-time win.
# On native Linux, bind mounts are already fast — default off.
MODEL_VOLUME_DEFAULT="no"
{ [ "$IS_WSL" = "true" ] || [ "$IS_GITBASH" = "true" ]; } && MODEL_VOLUME_DEFAULT="yes"

# Model storage: resolve to Windows home so Git Bash and WSL share the same folder.
# Git Bash $HOME is already the Windows home (/c/Users/...).
# In WSL, query the Windows USERPROFILE via cmd.exe and convert with wslpath.
# WIN_HOME is also used as the base for other cross-shell shared paths (e.g. .ai-coder-env).
WIN_HOME="$HOME"
if [ "$IS_WSL" = "true" ]; then
    _win_home=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')
    if [ -n "$_win_home" ]; then
        WIN_HOME="$(wslpath "$_win_home")"
        MODEL_STORAGE_DIR="$WIN_HOME/ai-models"
    else
        MODEL_STORAGE_DIR="${MODEL_STORAGE_DIR:-$HOME/ai-models}"
    fi
else
    MODEL_STORAGE_DIR="${MODEL_STORAGE_DIR:-$HOME/ai-models}"
fi
if [ "$IS_GITBASH" = "true" ]; then
    SMI="nvidia-smi.exe"
else
    SMI="nvidia-smi"
fi

to_host_path() {
    local abs_path; abs_path=$(realpath "$1")
    if [ "$IS_WSL" = "true" ]; then
        echo "$abs_path"
    elif [ "$IS_GITBASH" = "true" ]; then
        cygpath -m "$abs_path"
    else
        echo "$abs_path" | sed 's/^\/\([a-z]\)\//\/\/\1\//'
    fi
}

ensure_host_dir_writable() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
    elif [ ! -w "$dir" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo chown -R "$USER" "$dir"
        else
            echo -e "${YELLOW}⚠ $dir is not writable and sudo is unavailable — config updates may fail.${NC}" >&2
        fi
    fi
}

merge_json_file() {
    # Merge all top-level keys from $1 (source) into $2 (destination).
    # Source keys overwrite matching destination keys; unmatched destination keys
    # are preserved. Falls back to plain cp if no JSON tool is available or the
    # destination doesn't yet exist.
    #
    # Git Bash: PowerShell — handles Windows paths natively, no MSYS_NO_PATHCONV issues.
    # WSL/Linux: python3 (always present).
    # Last resort: cp — overwrites existing settings.
    local src="$1" dst="$2"
    local _merged=false
    if [ "$IS_GITBASH" = "true" ] && [ -f "$dst" ]; then
        local _ps1; _ps1=$(mktemp --suffix=.ps1)
        local _w_src; _w_src=$(cygpath -w "$src")
        local _w_dst; _w_dst=$(cygpath -w "$dst")
        local _w_ps1; _w_ps1=$(cygpath -w "$_ps1")
        cat > "$_ps1" <<PS1EOF
\$u = Get-Content -Raw -LiteralPath '$_w_src' | ConvertFrom-Json
\$e = try { Get-Content -Raw -LiteralPath '$_w_dst' | ConvertFrom-Json } catch { [PSCustomObject]@{} }
foreach (\$p in \$u.PSObject.Properties) {
    \$e | Add-Member -Force -MemberType NoteProperty -Name \$p.Name -Value \$p.Value
}
\$e | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 -LiteralPath '$_w_dst'
PS1EOF
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$_w_ps1" 2>/dev/null \
            && _merged=true
        rm -f "$_ps1"
    elif [ -f "$dst" ] && python3 -c "" >/dev/null 2>&1; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    new = json.load(f)
try:
    with open(sys.argv[2]) as f:
        old = json.load(f)
    new = {**old, **new}
except Exception:
    pass
with open(sys.argv[2], 'w') as f:
    json.dump(new, f, indent=2)
" "$src" "$dst" && _merged=true
    fi
    if [ "$_merged" = "false" ]; then
        [ -f "$dst" ] && echo -e "${YELLOW}⚠ No JSON merge tool available — overwriting $(basename "$dst"); existing settings in it are lost.${NC}" >&2
        cp "$src" "$dst"
    fi
}

# Read a package list file: one package per line, # comments stripped.
read_package_list() {
    local file="$1"
    [ -f "$file" ] && grep -v '^\s*#' "$file" | grep -v '^\s*$' | tr -d '\r' | tr '\n' ' ' || echo ""
}

# Read MCP npm package names from one or more server list files.
# Usage: read_mcp_packages <file1> [file2 ...]
# File format (pipe-delimited): npm-package | server-key | command | args...
# Lines whose package field starts with "pip:" are skipped (pip-only servers).
read_mcp_packages() {
    local file
    for file in "$@"; do
        [ -f "$file" ] || continue
        grep -v '^\s*#' "$file" | grep -v '^\s*$' | tr -d '\r' | \
            awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 != "" && substr($1,1,4) != "pip:") printf "%s ", $1}'
    done
}

# Read MCP pip package names from one or more server list files.
# Usage: read_mcp_pip_packages [--offline|--online] <file1> [file2 ...]
#   --offline  Only return packages whose net_req field is blank (work without internet).
#   --online   Only return packages whose net_req field is "online".
#   (default)  Return all pip packages regardless of net_req.
# Only returns entries whose package field starts with "pip:" (strips the prefix).
read_mcp_pip_packages() {
    local net_filter="all"
    if [[ "${1:-}" == "--offline" ]]; then net_filter="offline"; shift; fi
    if [[ "${1:-}" == "--online"  ]]; then net_filter="online";  shift; fi
    local file
    for file in "$@"; do
        [ -f "$file" ] || continue
        grep -v '^\s*#' "$file" | grep -v '^\s*$' | tr -d '\r' | \
            awk -F'|' -v nf="$net_filter" '{
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
                if (substr($1,1,4) != "pip:") next
                is_online = ($6 == "online") ? 1 : 0
                if (nf == "offline" && is_online) next
                if (nf == "online"  && !is_online) next
                printf "%s ", substr($1,5)
            }'
    done
}

_mcp_trim() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Escape a value for embedding inside a JSON double-quoted string.
_mcp_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

_mcp_build_env_json() {
    # Parses comma-separated env var specs into a JSON env fragment.
    # "NAME"        → expands $NAME from the calling environment
    # "NAME=value"  → literal value (supports {workspace} substitution)
    # Output: ', "env": {...}' / ', "environment": {...}' or empty.
    local env_vars_str="$1" workspace="$2" mode="$3"
    [ -z "$env_vars_str" ] && return
    local env_parts=() env_name
    IFS=',' read -ra env_names <<< "$env_vars_str"
    for env_name in "${env_names[@]}"; do
        env_name=$(_mcp_trim "$env_name")
        [ -z "$env_name" ] && continue
        if [[ "$env_name" == *=* ]]; then
            local ev_key="${env_name%%=*}"
            local ev_val; ev_val=$(printf '%s' "${env_name#*=}" | sed "s|{workspace}|$workspace|g")
            env_parts+=("\"$ev_key\": \"$(_mcp_json_escape "$ev_val")\"")
        else
            env_parts+=("\"$env_name\": \"$(_mcp_json_escape "${!env_name:-}")\"")
        fi
    done
    [ "${#env_parts[@]}" -eq 0 ] && return
    local env_joined; env_joined=$(printf ',%s' "${env_parts[@]}")
    local env_field="env"
    [ "$mode" = "opencode" ] && env_field="environment"
    printf ', "%s": {%s}' "$env_field" "${env_joined:1}"
}

_mcp_format_entry() {
    # Formats one MCP server JSON entry for the given mode.
    # standard (Claude/Gemini): {"command": "...", "args": [...], "env": {...}}
    # opencode:                 {"type": "local", "command": [...], "enabled": true, "environment": {...}}
    local mode="$1" key="$2" cmd="$3" args_str="$4" env_json="$5"
    local arr=() a
    for a in $args_str; do arr+=("\"$(_mcp_json_escape "$a")\""); done
    if [ "$mode" = "opencode" ]; then
        local oc_arr=("\"$cmd\"")
        [ "${#arr[@]}" -gt 0 ] && oc_arr+=("${arr[@]}")
        local oc_joined; oc_joined=$(printf ',%s' "${oc_arr[@]}")
        printf '    "%s": {"type": "local", "command": [%s], "enabled": true%s}' \
            "$key" "${oc_joined:1}" "$env_json"
    else
        local args_json="[]"
        if [ "${#arr[@]}" -gt 0 ]; then
            local joined; joined=$(printf ',%s' "${arr[@]}"); args_json="[${joined:1}]"
        fi
        printf '    "%s": {"command": "%s", "args": %s%s}' "$key" "$cmd" "$args_json" "$env_json"
    fi
}

# Emit indented mcpServers JSON entries from one or more server list files.
# Usage: make_mcp_servers_json <workspace-path> <mode> <file1> [file2 ...]
# mode: "standard" (Claude / Gemini format) or "opencode"
# File format (pipe-delimited): npm-pkg | server-key | command | arg1 arg2 ... | ENV_VAR1,ENV_VAR2 | net
# Use {workspace} in args as a placeholder for <workspace-path>.
# The optional 5th field lists env var *names* (comma-separated) whose values are
# expanded from the calling environment and embedded in the generated config.
# The optional 6th field: set to "online" to skip the server when NETWORK_INTERNAL=true.
make_mcp_servers_json() {
    local workspace="$1" mode="${2:-standard}"
    shift 2
    local entries=()
    local file
    for file in "$@"; do
        [ -f "$file" ] || continue
        while IFS='|' read -r pkg key cmd args_str env_vars_str net_req; do
            pkg=$(_mcp_trim "$pkg"); pkg="${pkg#pip:}"
            [[ "$pkg" =~ ^# ]] && continue
            [ -z "$pkg" ] && continue
            [ "$(_mcp_trim "${net_req:-}")" = "online" ] && [ "${NETWORK_INTERNAL:-false}" = "true" ] && continue
            key=$(_mcp_trim "$key")
            cmd=$(_mcp_trim "$cmd")
            args_str=$(printf '%s' "$args_str" | tr -d '\r' | \
                sed "s|{workspace}|$workspace|g;s/^[[:space:]]*//;s/[[:space:]]*$//")
            local env_json; env_json=$(_mcp_build_env_json "$(_mcp_trim "${env_vars_str:-}")" "$workspace" "$mode")
            entries+=("$(_mcp_format_entry "$mode" "$key" "$cmd" "$args_str" "$env_json")")
        done < "$file"
    done
    local i
    for i in "${!entries[@]}"; do
        if [ "$i" -lt $(( ${#entries[@]} - 1 )) ]; then
            printf '%s,\n' "${entries[$i]}"
        else
            printf '%s\n' "${entries[$i]}"
        fi
    done
}

# Emit the mcpServers JSON entries an agent should register this launch:
# core servers (mcp-common.txt), optional extras (mcp-extra.txt, only when
# enabled via --setup), and the agent's own server file.
# Usage: make_agent_mcp_json <workspace-path> <mode> <agent-mcp-file-basename>
make_agent_mcp_json() {
    local workspace="$1" mode="$2" agent_file="$3"
    local files=("$PACKAGES_DIR/mcp-common.txt")
    if [ "$(read_pref "$SETTINGS_FILE" mcp_extras no)" = "yes" ]; then
        files+=("$PACKAGES_DIR/mcp-extra.txt")
    fi
    files+=("$PACKAGES_DIR/$agent_file")
    make_mcp_servers_json "$workspace" "$mode" "${files[@]}"
}

_fetch_release_hash() {
    local api_url="https://api.github.com/repos/ggilman/ai_coder/git/refs/heads/release"
    local http_proxy=""
[ -n "${DOWNLOAD_PROXY:-}" ] && http_proxy=$(resolve_proxy_to_ip "$(echo "$DOWNLOAD_PROXY" | sed "s|^https://|http://|")")
    if command -v curl >/dev/null 2>&1; then
        local curl_args=(-fsSL --connect-timeout 4)
        [ -n "$http_proxy" ] && curl_args+=(--proxy "$http_proxy")
        curl "${curl_args[@]}" "$api_url" 2>/dev/null \
            | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]{40}"' \
            | head -1 | grep -oE '[a-f0-9]{40}' || true

    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "$http_proxy" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$http_proxy" -e "https_proxy=$http_proxy")
        wget -qO- --timeout=4 "${wget_proxy_args[@]}" "$api_url" 2>/dev/null \
            | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]{40}"' \
            | head -1 | grep -oE '[a-f0-9]{40}' || true

    fi
}
check_for_update() {
    local install_dir; install_dir="$(dirname "$SCRIPT_DIR")"
    local interval=86400 # 24 hours

    local last_check; last_check=$(read_pref "$STATE_FILE" last_check 0)
    local now; now=$(date +%s 2>/dev/null || echo 0)
    if [ $(( now - last_check )) -lt $interval ]; then return; fi

    local remote_hash; remote_hash=$(_fetch_release_hash)
    if [ -z "$remote_hash" ]; then
        # Fetch failed (offline / proxy down). Back off for an hour instead of
        # paying the connection timeout on every launch, but don't wait the
        # full daily interval so updates are noticed soon after coming online.
        write_pref "$STATE_FILE" last_check "$(( now - interval + 3600 ))"
        return
    fi

    write_pref "$STATE_FILE" last_check "$now"

    local local_hash; local_hash=$(read_pref "$STATE_FILE" release_hash "")

    # No recorded hash: first run after install. Save remote hash and assume up to date.
    if [ -z "$local_hash" ]; then
        write_pref "$STATE_FILE" release_hash "$remote_hash"
        return
    fi

    [ "$local_hash" = "$remote_hash" ] && return

    echo -e "${YELLOW}◈ Update available — run: ${CYAN}$(realpath "$install_dir/ai-coder") --update${NC}"
}

# Read a key=value entry from a preference file. Returns the value, or $default if missing.
read_pref() {
    local file="$1" key="$2" default="${3:-}"
    if [ -f "$file" ]; then
        local val; val=$(grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-) || true
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

# Write or update a single key=value entry in a preference file.
# Creates the file and its parent directory if needed. Clears the key when value is empty.
write_pref() {
    local file="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$file")"
    if [ -f "$file" ] && grep -q "^${key}=" "$file" 2>/dev/null; then
        grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null || true
        mv "${file}.tmp" "$file"
    fi
    [ -n "$value" ] && printf '%s=%s\n' "$key" "$value" >> "$file" || true
}

# One-time migration from the old $HOME/.ai-coder-* per-file layout to the
# consolidated user/settings.conf + user/state.conf files in the install directory.
# Runs only when neither destination file exists yet; deletes the old files on success.
# Resolve proxy hostname to IP so Docker build containers can reach it.
# getent is Linux-only; fall back to nslookup (available in Git Bash + WSL).
resolve_proxy_to_ip() {
    local proxy_url="$1"
    local host_port; host_port=$(echo "$proxy_url" | sed 's|.*://||;s|/.*||')
    # Pre-bracketed IPv6 literal (e.g. http://[::1]:3128) — already resolved, return as-is
    if [[ "$host_port" == \[*\]* ]]; then
        echo "$proxy_url"
        return
    fi
    local host="${host_port%%:*}"
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup "$host" 2>/dev/null | tr -d '\r' | awk '/^Address:/{ip=$2} END{print ip}' | head -1)
    fi
    if [ -n "$ip" ]; then
        # If the IP address contains a colon, it's likely IPv6 and needs brackets
        if [[ "$ip" == *:* ]]; then
            echo "$proxy_url" | sed "s|$host|[$ip]|"
        else
            echo "$proxy_url" | sed "s|$host|$ip|"
        fi
    else
        echo "$proxy_url"
    fi
}

# --- [ GIT IDENTITY ] ---------------------------------------------------------

# Load or prompt for git user identity, then store it for future runs.
# Sets GIT_USER_EMAIL and GIT_USER_NAME in the calling environment.
ensure_git_identity() {
    local git_email; git_email=$(read_pref "$SETTINGS_FILE" git_email "")
    local git_name;  git_name=$(read_pref  "$SETTINGS_FILE" git_name  "")
    [ -z "$git_email" ] && git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$git_name"  ] && git_name=$(git config  --global user.name  2>/dev/null || true)
    export GIT_USER_EMAIL="${git_email:-}"
    export GIT_USER_NAME="${git_name:-}"
}

# --- [ NETWORK CONFIG ] -------------------------------------------------------

# Load or prompt for network isolation preference, then store it for future runs.
# Sets NETWORK_INTERNAL in the calling environment.
ensure_network_config() {
    local isolated_net; isolated_net=$(read_pref "$SETTINGS_FILE" isolated no)
    [ "$isolated_net" = "yes" ] && NETWORK_INTERNAL=true || true
}

# Load or prompt for GPU mode preference, then store it for future runs.
# Sets GPU_MODE in the calling environment ("multi" or "single").
# Silently skips the prompt when only one GPU is present.
ensure_gpu_config() {
    GPU_MODE=$(read_pref "$SETTINGS_FILE" gpu_mode multi)
}

# Sets MODEL_CTX_LEVEL (and derives MODEL_CTX_SIZE) from the saved preference.
# Falls back to the default defined in ai-coder-model.conf when no pref is saved.
ensure_ctx_config() {
    local _level; _level=$(read_pref "$SETTINGS_FILE" ctx_level "")
    [ -n "$_level" ] && MODEL_CTX_LEVEL="$_level"
    # Re-derive MODEL_CTX_SIZE from the (possibly updated) level.
    case "${MODEL_CTX_LEVEL:-64k}" in
        4k)   MODEL_CTX_SIZE=4096   ;;
        8k)   MODEL_CTX_SIZE=8192   ;;
        16k)  MODEL_CTX_SIZE=16384  ;;
        32k)  MODEL_CTX_SIZE=32768  ;;
        64k)  MODEL_CTX_SIZE=65536  ;;
        128k) MODEL_CTX_SIZE=131072 ;;
        256k) MODEL_CTX_SIZE=262144 ;;
        *)    MODEL_CTX_SIZE=65536  ;;
    esac
}

# Write a ~/.gitconfig-container file that gets mounted into containers as
# /root/.gitconfig so git commands in any repo (including newly init'd ones)
# pick up the correct author identity.
# Always writes the file — run_workbench bind-mounts it unconditionally, and a
# missing mount source would make Docker create it as a root-owned directory.
ensure_container_gitconfig() {
    local gitcfg="$HOME/.gitconfig-container"
    # Recover from a previous run where Docker created this path as a directory.
    if [ -d "$gitcfg" ]; then
        rm -rf "$gitcfg" 2>/dev/null || sudo rm -rf "$gitcfg" 2>/dev/null || true
    fi
    # Normalize CRLF→LF inside containers (Windows host mounts files with CRLF).
    cat > "$gitcfg" <<GITCFG
[core]
    autocrlf = input
GITCFG
    if [ -n "${GIT_USER_EMAIL:-}" ] || [ -n "${GIT_USER_NAME:-}" ]; then
        local email="${GIT_USER_EMAIL:-developer@localhost}"
        local name="${GIT_USER_NAME:-Developer}"
        # Escape backslashes and double-quotes for git config quoted-value syntax.
        # Wrapping in double quotes makes # and ; safe (not treated as comments).
        email="${email//\\/\\\\}"; email="${email//\"/\\\"}"
        name="${name//\\/\\\\}";   name="${name//\"/\\\"}"
        cat >> "$gitcfg" <<GITCFG
[user]
    email = "${email}"
    name = "${name}"
GITCFG
    fi
}

# Write identity into the local repo's .git/config (host-side).
# The workspace volume mount means the container sees this immediately.
# Skips gracefully if not inside a git repo or if already configured.
apply_git_identity() {
    if ! git -C "$(pwd)" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi
    local cur_email; cur_email=$(git -C "$(pwd)" config --local user.email 2>/dev/null || true)
    local cur_name;  cur_name=$(git  -C "$(pwd)" config --local user.name  2>/dev/null || true)
    [ -z "$cur_email" ] && [ -n "${GIT_USER_EMAIL:-}" ] && git -C "$(pwd)" config --local user.email "$GIT_USER_EMAIL"
    [ -z "$cur_name"  ] && [ -n "${GIT_USER_NAME:-}"  ] && git -C "$(pwd)" config --local user.name  "$GIT_USER_NAME"
    # Normalize CRLF→LF on checkout inside the container (Windows host mounts files with CRLF).
    # 'input' strips CR on add but never introduces CR on checkout — safe for all platforms.
    git -C "$(pwd)" config --local core.autocrlf input 2>/dev/null || true
    [ -n "${GIT_USER_NAME:-}" ] && printf "%s Git identity: %s%s${NC} <%s>\n" "${ICON_OK}" "${CYAN}" "${GIT_USER_NAME}" "${GIT_USER_EMAIL}"
}

# --- [ CORE LOGIC ] -----------------------------------------------------------

check_docker() {
    # Verify the docker binary is reachable from this shell before anything else.
    # On some machines Docker is installed but its CLI is not on the PATH when
    # running from Git Bash (e.g. missing entry in /etc/paths or a broken
    # Desktop integration), which causes every subsequent docker call to fail
    # with "command not found" in a confusing way.
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}✘ Docker CLI not found in PATH.${NC}"
        echo -e "${YELLOW}  Docker may be installed but is not accessible from this shell.${NC}"
        echo -e "${CYAN}  Try reopening Git Bash after a fresh Docker Desktop install,${NC}"
        echo -e "${CYAN}  or run from PowerShell / WSL where Docker is reachable.${NC}"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${ICON_GEAR} Starting Docker Desktop..."
        if [ "$IS_WSL" == "true" ]; then
            if [ -n "$DOCKER_BIN" ]; then
                powershell.exe -Command "Start-Process '$DOCKER_BIN'" >/dev/null 2>&1 || {
                    echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
                }
            else
                powershell.exe -Command "Start-Process 'Docker Desktop'" >/dev/null 2>&1 || {
                    echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
                }
            fi
        else
            if [ -n "$DOCKER_BIN" ]; then
                # Use powershell.exe Start-Process rather than Git Bash's `start` shim.
                # The `start` shim invokes cmd.exe which hijacks the console and detaches
                # Git Bash from its own terminal window. PowerShell launches the process
                # detached without touching the calling terminal.
                # cygpath converts the MSYS path to a Windows path for PowerShell.
                local _start_bin="$DOCKER_BIN"
                [ "$IS_GITBASH" = "true" ] && _start_bin=$(cygpath -w "$DOCKER_BIN")
                powershell.exe -Command "Start-Process '$_start_bin'" >/dev/null 2>&1 || {
                    echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
                }
            else
                echo -e "${RED}✘ Docker Desktop not found — start it manually and retry.${NC}"; return 1
            fi
        fi
        
        local wait_count=0
        echo -ne "${CYAN}◈ Waiting for Daemon...${NC} "
        until docker info >/dev/null 2>&1; do 
            wait_count=$((wait_count + 1))
            if [ "$wait_count" -gt 60 ]; then
                echo -e " ${RED}TIMEOUT${NC}"; return 1
            fi
            echo -ne "◈"; sleep 5
        done
        echo -e " ${GREEN}ONLINE${NC}"
    fi

    # Daemon is up — run a basic command to confirm the CLI actually works in
    # this shell context.  On certain Windows machines `docker info` succeeds
    # (it uses a simpler pipe path) while other commands like `docker ps` fail
    # due to permission or socket issues specific to the Git Bash environment.
    if ! docker ps >/dev/null 2>&1; then
        echo -e "${RED}✘ Docker daemon is running but commands fail from this shell.${NC}"
        echo -e "${YELLOW}  This is a known issue on some Windows machines with Git Bash.${NC}"
        echo -e "${CYAN}  Possible fixes:${NC}"
        echo -e "${CYAN}    • Add your user to the 'docker-users' group and log out/in${NC}"
        echo -e "${CYAN}    • Run Docker Desktop as Administrator once to repair permissions${NC}"
        echo -e "${CYAN}    • Use PowerShell or WSL instead of Git Bash${NC}"
        return 1
    fi
}

# Estimate the KV-cache VRAM reserve in GB (rounded up) for the active
# context size and KV quantization type.
# Exact KV size is model-specific (layers x KV-heads x head-dim), which the
# launcher can't know before a model is chosen. Across this project's model
# range (8B-35B GQA models) q8_0 KV costs ~64-140 KB per token; 96 KiB/token
# is used as a middle estimate, scaled for the KV quant type. Override with
# MODEL_KV_BYTES_PER_TOKEN in a family conf for models far from that band.
_estimate_kv_reserve_gb() {
    local _bpt_default
    case "${MODEL_KV_TYPE:-q8_0}" in
        f16|bf16)  _bpt_default=196608 ;;
        q4_0|q4_1) _bpt_default=49152  ;;
        *)         _bpt_default=98304  ;;
    esac
    local _bpt="${MODEL_KV_BYTES_PER_TOKEN:-$_bpt_default}"
    echo $(( (${MODEL_CTX_SIZE:-65536} * _bpt + 1073741823) / 1073741824 ))
}

# Walks the MODEL_1..MODEL_N candidate list defined by the active family conf,
# in priority order (best quality first), and selects the first entry whose
# MODEL_N_WEIGHTS_GB fits within the supplied VRAM headroom (already KV-cache
# and draft reserve subtracted). Sets MODEL_FILE, MODEL_URL, MODEL_SHA256, and
# MODEL_TIER in the caller's environment.
# The last candidate should have MODEL_N_WEIGHTS_GB=0 — it is always selected
# unconditionally as the fallback when nothing larger fits.
select_model_for_vram() {
    local vram="${1:-0}" i _fv _wv _uv _sv _dv _w
    local _count="${MODEL_COUNT:-0}"
    for (( i=1; i<=_count; i++ )); do
        _fv="MODEL_${i}_FILE"
        [ -z "${!_fv:-}" ] && break
        _wv="MODEL_${i}_WEIGHTS_GB"
        _w="${!_wv:-0}"
        if [ "$vram" -ge "$_w" ]; then
            _uv="MODEL_${i}_URL"
            _sv="MODEL_${i}_SHA256"
            _dv="MODEL_${i}_DESC"
            MODEL_FILE="${!_fv}"
            MODEL_URL="${!_uv:-}"
            MODEL_SHA256="${!_sv:-}"
            MODEL_TIER="${!_dv:-model-$i}"
            return
        fi
    done
    # Should not reach here when the last entry has WEIGHTS_GB=0.
    # Safety fallback: use last defined candidate.
    i=$(( _count > 0 ? _count : 1 ))
    _fv="MODEL_${i}_FILE"; _uv="MODEL_${i}_URL"
    _sv="MODEL_${i}_SHA256"; _dv="MODEL_${i}_DESC"
    MODEL_FILE="${!_fv:-}"
    MODEL_URL="${!_uv:-}"
    MODEL_SHA256="${!_sv:-}"
    MODEL_TIER="${!_dv:-fallback}"
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

# True when speculative decoding should be used: the setting is on (default)
# and the active model family defines a draft model.
spec_decode_enabled() {
    [ "$(read_pref "$SETTINGS_FILE" spec_decode yes)" = "yes" ] && [ -n "${MODEL_DRAFT_FILE:-}" ]
}

# Download the family's speculative-decoding draft model if missing.
download_draft_model() {
    local dest="$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE"
    [ -f "$dest" ] && return 0
    [ -n "${MODEL_DRAFT_URL:-}" ] || return 1
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

# Format a byte count as a human-readable size.
# numfmt is not available in Git Bash — use awk for portability.
_human_size() {
    awk -v b="${1:-0}" 'BEGIN{
        s=b+0; u="B"
        if(s>=1073741824){s=s/1073741824; u="GiB"}
        else if(s>=1048576){s=s/1048576; u="MiB"}
        else if(s>=1024){s=s/1024; u="KiB"}
        printf "%.1f%s", s, u
    }'
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

# Returns Dockerfile RUN commands to configure npm proxy, or empty string if no proxy.
make_npm_proxy_cmds() {
    [ -z "${DOWNLOAD_PROXY:-}" ] && return
    local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
    local npm_proxy; npm_proxy=$(echo "$build_proxy" | sed 's|^https://|http://|')
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
    if [ -z "${DOWNLOAD_PROXY:-}" ]; then
        echo "pip3 install --break-system-packages"
        return
    fi
    local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
    local pip_proxy; pip_proxy=$(echo "$build_proxy" | sed 's|^https://|http://|')
    echo "env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY pip3 install --break-system-packages --proxy $pip_proxy --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org"
}

build_pip_install_cmds() {
    # Usage: build_pip_install_cmds <pip_proxy_cmds> <offline_pkgs> <online_pkgs>
    # Returns Dockerfile RUN lines for offline pip packages (required) and online
    # pip packages (best-effort, || true). Used by agent build_image() functions.
    local pip_proxy_cmds="$1" mcp_pip_pkgs="$2" mcp_pip_online="$3"
    local pip_cmd=""
    if [ -n "$(echo "$mcp_pip_pkgs" | tr -d ' ')" ]; then
        pip_cmd=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_pkgs}"
    fi
    if [ -n "$(echo "$mcp_pip_online" | tr -d ' ')" ]; then
        pip_cmd+=$'\nRUN '"${pip_proxy_cmds} ${mcp_pip_online} || true"
    fi
    printf '%s' "$pip_cmd"
}

download_model() {
    if [ -n "${MODEL_FILE:-}" ] && [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        return 0
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

detect_model() {
    local vram_list; vram_list=$($SMI --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') || {
        echo -e "${RED}✘ nvidia-smi failed${NC}"; return 1
    }

    local total_vram=0 gpu_idx=0
    for v in $vram_list; do
        case "$v" in *[!0-9]*) gpu_idx=$((gpu_idx + 1)); continue ;; esac
        # In single-GPU mode only count VRAM from GPU 0 so the tier selection
        # matches what will actually be available to the engine container.
        if [ "${GPU_MODE:-multi}" = "single" ] && [ "$gpu_idx" -gt 0 ]; then
            gpu_idx=$((gpu_idx + 1)); continue
        fi
        total_vram=$((total_vram + v))
        gpu_idx=$((gpu_idx + 1))
    done
    VRAM_GB=$((total_vram / 1024))

    echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC}"

    # Reserve estimated KV-cache VRAM before picking a tier — a model that
    # fills the card leaves no room for the KV cache at the chosen context
    # size, causing OOM or RAM spill (which makes inference crawl).
    # The speculative-decoding draft model occupies VRAM too when enabled.
    local kv_reserve; kv_reserve=$(_estimate_kv_reserve_gb)
    local draft_reserve=0 _draft_note=""
    if spec_decode_enabled; then
        draft_reserve="${MODEL_DRAFT_VRAM_GB:-1}"
        _draft_note=" + ${draft_reserve}GB draft"
    fi
    EFFECTIVE_VRAM_GB=$(( VRAM_GB - kv_reserve - draft_reserve ))
    [ "$EFFECTIVE_VRAM_GB" -lt 0 ] && EFFECTIVE_VRAM_GB=0
    echo -e "${ICON_GEAR} VRAM Reserve: ${BOLD}~${kv_reserve}GB KV${NC} ${DIM}(${MODEL_CTX_LEVEL:-64k} ctx, ${MODEL_KV_TYPE:-q8_0})${_draft_note}${NC} → ${BOLD}${EFFECTIVE_VRAM_GB}GB${NC} usable for model"

    # Record which model raw VRAM (no overhead) would allow, to detect when
    # the context/draft reserve causes a step down to a smaller model.
    select_model_for_vram "$VRAM_GB"
    local _raw_tier="$MODEL_TIER"

    select_model_for_vram "$EFFECTIVE_VRAM_GB"
    echo -e "${ICON_GEAR} Model: ${BOLD}${MODEL_TIER}${NC}"
    echo -e "${ICON_GEAR} File:  ${CYAN}${MODEL_FILE}${NC}"
    if [ "$MODEL_TIER" != "$_raw_tier" ]; then
        local _tier_reason="${MODEL_CTX_LEVEL:-64k} context reserve"
        [ -n "$_draft_note" ] && _tier_reason="${MODEL_CTX_LEVEL:-64k} context + ${draft_reserve}GB draft reserve"
        echo -e "${DIM}  ↓ ${_tier_reason} (~${kv_reserve}GB) reduces model headroom to ${EFFECTIVE_VRAM_GB}GB; ${_raw_tier} doesn't fit.${NC}"
        echo -e "${DIM}    Lower the context level in --setup to free up headroom and unlock the larger model.${NC}"
    fi
    
    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${ICON_OK} Target Model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi

    echo -e "${YELLOW}⚠ Target model not found locally — will download: ${CYAN}${MODEL_FILE}${NC}"
    return 0
}

pull_base_image_via_proxy() {
    local image="$1" proxy="$2"

    # Git Bash: Docker Desktop is a native Windows app using the Windows cert store.
    # It handles proxy natively — just set env vars and docker pull works directly.
    if [ "$IS_GITBASH" = "true" ]; then
        echo -e "${CYAN}  Pulling $image via Docker Desktop (Windows proxy)...${NC}"
        HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" docker pull "$image" || {
            echo -e "${RED}  ✘ Base image pull failed${NC}"; return 1
        }
        return 0
    fi

    # In WSL2 the Docker daemon runs inside Docker Desktop (Windows), which has
    # its own proxy settings configured via the Docker Desktop GUI — independent
    # of WSL env vars. Try plain docker pull first; it often works even when the
    # proxy is unreachable from the WSL shell itself.
    echo -e "${CYAN}  Pulling $image via Docker Desktop (WSL2)...${NC}"
    if docker pull "$image" 2>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}  Plain pull failed — attempting crane for proxy-aware pull...${NC}"

    local crane_bin crane_tmp=""
    crane_bin=$(command -v crane 2>/dev/null)
    if [ -z "$crane_bin" ]; then
        local crane_url="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz"
        crane_tmp=$(mktemp -d)
        # Try without proxy first (--noproxy overrides env http_proxy), then via proxy.
        echo -e "${CYAN}  Downloading crane (registry pull tool) directly...${NC}"
        if curl --noproxy '*' -fsSL --connect-timeout 15 "$crane_url" 2>/dev/null | tar xz -C "$crane_tmp" crane 2>/dev/null; then
            crane_bin="$crane_tmp/crane"
        else
            echo -e "${CYAN}  Direct download failed, retrying via proxy...${NC}"
            if curl --proxy "$proxy" -fsSL --connect-timeout 30 "$crane_url" | tar xz -C "$crane_tmp" crane; then
                crane_bin="$crane_tmp/crane"
            else
                echo -e "${YELLOW}  ✘ crane unavailable — trying docker pull with explicit proxy env vars${NC}"
                rm -rf "$crane_tmp"
                HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" docker pull "$image" || {
                    echo -e "${RED}  ✘ Base image pull failed${NC}"; return 1
                }
                return 0
            fi
        fi
    fi
    echo -e "${CYAN}  Pulling $image from registry via proxy (crane)...${NC}"
    local image_tar; image_tar=$(mktemp --suffix=.tar)
    if HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" "$crane_bin" pull "$image" "$image_tar"; then
        echo -e "${CYAN}  Loading image into Docker...${NC}"
        if docker load < "$image_tar"; then
            rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
            return 0
        else
            rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
            return 1
        fi
    else
        echo -e "${RED}  ✘ crane pull failed${NC}"
        rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
        return 1
    fi
}

pull_image_if_missing() {
    local img="$1"
    docker image inspect "$img" >/dev/null 2>&1 && return 0
    echo -e "${CYAN}  Pulling $img ...${NC}"
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        pull_base_image_via_proxy "$img" "$DOWNLOAD_PROXY" || { echo -e "${RED}✘ Failed to pull $img${NC}"; return 1; }
    else
        docker pull "$img" || { echo -e "${RED}✘ Failed to pull $img${NC}"; return 1; }
    fi
}

# --- [ WORKBENCH HELPERS ] ----------------------------------------------------

_write_standard_dockerfile() {
    local build_dir="$1" df_name="$2" apt_pkgs="$3" pm_proxy_cmds="$4" install_cmds="$5"
    local _proxy_env_block=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        _proxy_env_block=$'ENV http_proxy=${PROXY_URL} https_proxy=${PROXY_URL} HTTP_PROXY=${PROXY_URL} HTTPS_PROXY=${PROXY_URL} \\\n    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1'
    fi
    cat > "$build_dir/$df_name" <<DOCKERFILE
FROM $BASE_IMAGE
ARG PROXY_URL
ARG GIT_USER_NAME
ARG GIT_USER_EMAIL
ENV DEBIAN_FRONTEND=noninteractive
RUN if [ -n "\${PROXY_URL}" ]; then \
      apt_proxy=\$(echo "\${PROXY_URL}" | sed 's|^https://|http://|') && \
      if [ -f /etc/apt/sources.list ]; then \
        sed -i 's|http://|https://|g' /etc/apt/sources.list; \
      fi && \
      if [ -d /etc/apt/sources.list.d ]; then \
        find /etc/apt/sources.list.d -name '*.list' -exec sed -i 's|http://|https://|g' {} +; \
      fi && \
      printf 'Acquire::https::Proxy "%s";\nAcquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' "\${apt_proxy}" > /etc/apt/apt.conf.d/01proxy; \
    fi
RUN apt-get update && apt-get install -y wget ca-certificates gnupg apt-transport-https --no-install-recommends && \
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | \
      gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
      > /etc/apt/sources.list.d/microsoft-prod.list && \
    apt-get update && apt-get install -y \
    ${apt_pkgs} \
    --no-install-recommends --fix-missing && rm -rf /var/lib/apt/lists/*
RUN if [ -n "\${GIT_USER_NAME}" ] && [ -n "\${GIT_USER_EMAIL}" ]; then \
      git config --global user.name "\${GIT_USER_NAME}" && \
      git config --global user.email "\${GIT_USER_EMAIL}"; \
    fi
${_proxy_env_block}
${pm_proxy_cmds}
${install_cmds}
DOCKERFILE
}

build_standard_image() {
    # Args: <dockerfile-name> <apt-pkgs> <pm-proxy-cmds> <install-cmds>
    local df_name="$1" apt_pkgs="$2" pm_proxy_cmds="$3" install_cmds="$4"

    if [ -n "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then return 0; fi

    pull_image_if_missing "$BASE_IMAGE" || return 1

    local proxy_args=()
    [ -n "${DOWNLOAD_PROXY:-}" ] && proxy_args=(--build-arg "PROXY_URL=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")")

    local git_args=()
    [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ] && \
        git_args=(--build-arg "GIT_USER_NAME=${GIT_USER_NAME}" --build-arg "GIT_USER_EMAIL=${GIT_USER_EMAIL}")

    local _build_dir; _build_dir=$(mktemp -d)
    trap 'rm -rf "$_build_dir"; trap - RETURN' RETURN

    _write_standard_dockerfile "$_build_dir" "$df_name" "$apt_pkgs" "$pm_proxy_cmds" "$install_cmds"

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" "${git_args[@]}" \
        -f "$(to_host_path "$_build_dir")/$df_name" \
        "$(to_host_path "$_build_dir")" || {
        echo -e "${RED}✘ Docker build failed${NC}"; return 1
    }
}

build_npm_agent_image() {
    # Shared build_image scaffolding for npm-based agents.
    # Args:
    #   $1  dockerfile name
    #   $2  agent-specific apt package file basename (under $PACKAGES_DIR)
    #   $3  agent-specific mcp package file basename (under $PACKAGES_DIR)
    #   $4  npm package(s) to pass to npm install -g
    #   $5  extra npm flags appended after mcp packages (e.g. "--quiet"), or ""
    #   $6  extra RUN line appended after npm install (e.g. "RUN gemini --version"), or ""
    local df_name="$1" apt_file="$2" mcp_file="$3" npm_pkg="$4" npm_extra_flags="${5:-}" verify_run="${6:-}"

    if [ -n "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then
        echo -e "${ICON_OK} ${TOOL_NAME} Image: ready."
        return 0
    fi
    echo -e "${ICON_GEAR} Building ${TOOL_NAME} Image..."
    local pm_proxy_cmds; pm_proxy_cmds=$(make_npm_proxy_cmds)
    local pip_proxy_cmds; pip_proxy_cmds=$(make_pip_proxy_cmds)
    local apt_pkgs; apt_pkgs="$(read_package_list "$PACKAGES_DIR/apt-common.txt") $(read_package_list "$PACKAGES_DIR/$apt_file")"
    # mcp-extra.txt servers are always installed in the image (so toggling the
    # MCP extras setting never requires a rebuild); registration in the agent
    # config is decided per-launch by make_agent_mcp_json.
    local mcp_pkgs; mcp_pkgs=$(read_mcp_packages "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-extra.txt" "$PACKAGES_DIR/$mcp_file")
    local mcp_pip_pkgs; mcp_pip_pkgs=$(read_mcp_pip_packages --offline "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-extra.txt" "$PACKAGES_DIR/$mcp_file")
    local mcp_pip_online; mcp_pip_online=$(read_mcp_pip_packages --online "$PACKAGES_DIR/mcp-common.txt" "$PACKAGES_DIR/mcp-extra.txt" "$PACKAGES_DIR/$mcp_file")
    local pip_cmd; pip_cmd=$(build_pip_install_cmds "$pip_proxy_cmds" "$mcp_pip_pkgs" "$mcp_pip_online")
    local install_cmds="RUN npm install -g ${npm_pkg} ${mcp_pkgs}${npm_extra_flags}${pip_cmd}"
    [ -n "$verify_run" ] && install_cmds+=$'\n'"$verify_run"
    build_standard_image "$df_name" "$apt_pkgs" "$pm_proxy_cmds" "$install_cmds"
}

exec_in_container() {
    # Usage: exec_in_container [extra docker exec flags...] <container> <cmd> [args...]
    # Handles winpty on Git Bash automatically.
    # NOTE: do NOT pass -e PATH=... here. On Git Bash, MSYS converts the colon-
    # separated value into Windows-style paths through the winpty boundary, which
    # the Linux container cannot use. docker exec inherits the container's
    # image-set PATH (which already includes /usr/local/bin for npm globals) and
    # that is sufficient.
    # On Git Bash, MSYS converts /foo paths to Windows paths when winpty is the
    # intermediary, even with MSYS_NO_PATHCONV=1. The // prefix suppresses MSYS
    # conversion (treated as a UNC prefix); Linux normalises //foo → /foo.
    local _wd="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wd="//$WORKSPACE_DIR"
    local cmd_args=(docker exec -it -w "$_wd" "$@")
    if [ "$IS_GITBASH" = "true" ]; then
        winpty "${cmd_args[@]}"
    else
        "${cmd_args[@]}"
    fi
}

run_workbench() {
    # Usage: run_workbench [extra docker run flags...] [-- <entrypoint-cmd>]
    # Starts the workbench with standard flags. Pass a custom entrypoint after --.
    local extra_flags=()
    local entrypoint="mkdir -p \"/$WORKSPACE_DIR\"; trap 'true' EXIT; while true; do sleep 3600; done"
    local past_sep=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then past_sep=true; continue; fi
        if $past_sep; then entrypoint="$arg"; else extra_flags+=("$arg"); fi
    done
    local wb_network="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && wb_network="$HUB_ISOLATED_NET"
    local no_proxy_hosts="localhost,127.0.0.1,$GLOBAL_ENGINE_NAME"
    [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ] && no_proxy_hosts="$no_proxy_hosts,$GLOBAL_PROXY_NAME"
    # When isolated, don't inject proxy env vars — the container has no internet
    # access anyway, and proxy settings can interfere with internal container
    # communication if no_proxy isn't perfectly honoured by every client.
    local _wb_http_proxy="${DOWNLOAD_PROXY:-}"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_http_proxy=""
    # On Git Bash, MSYS may still convert /$WORKSPACE_DIR to a Windows path for
    # --workdir even with MSYS_NO_PATHCONV=1. The // prefix suppresses conversion
    # and Linux containers normalise //foo → /foo.
    local _wb_workdir="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wb_workdir="//$WORKSPACE_DIR"
    # No --privileged: agents only need the workspace mount and network access,
    # and a privileged container would undermine the network-isolation option.
    # --stop-timeout 2: the keep-alive entrypoint ignores SIGTERM, so a short
    # grace period avoids a 10s docker stop hang on every exit.
    docker run -d --name "$WORKBENCH" --network "$wb_network" --stop-timeout 2 \
        -e "http_proxy=${_wb_http_proxy}" -e "https_proxy=${_wb_http_proxy}" \
        -e "HTTP_PROXY=${_wb_http_proxy}" -e "HTTPS_PROXY=${_wb_http_proxy}" \
        -e "no_proxy=$no_proxy_hosts" -e "NO_PROXY=$no_proxy_hosts" \
        -v "$(to_host_path "$(pwd)"):/$WORKSPACE_DIR" \
        -v "$(to_host_path "$HOME/.gitconfig-container"):/root/.gitconfig:ro" \
        --workdir "$_wb_workdir" \
        "${extra_flags[@]}" \
        "$IMAGE_NAME" /bin/bash -c "$entrypoint" > /dev/null
}

_resolve_engine_gpu_args() {
    # Sets _gpus_flag, _ts_args, _cuda_env for the caller based on GPU_MODE.
    # "single": exposes only GPU 0; also sets CUDA_VISIBLE_DEVICES to guard against
    # Docker Desktop / WSL2 passthrough quirks where --gpus device=0 isn't fully enforced.
    # "multi": exposes all GPUs and builds --tensor-split from per-GPU VRAM so llama.cpp
    # distributes compute (not just VRAM) across every card.
    _gpus_flag="all"
    _ts_args=()
    _cuda_env=()
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
        _cuda_env=(-e CUDA_VISIBLE_DEVICES=0)
        echo -e "${ICON_GEAR} GPU Mode: ${YELLOW}Single (GPU 0 only)${NC}"
    else
        local _vram_raw; _vram_raw=$($SMI --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') || true
        local _split_vals=()
        for _v in $_vram_raw; do
            case "$_v" in *[!0-9]*) ;; *) _split_vals+=("$_v") ;; esac
        done
        if [ "${#_split_vals[@]}" -gt 1 ]; then
            local _ts; _ts=$(IFS=,; echo "${_split_vals[*]}")
            _ts_args=(--tensor-split "$_ts")
            echo -e "${ICON_GEAR} GPU Mode: ${GREEN}Multi — distributing across ${#_split_vals[@]} GPUs (split: ${CYAN}${_ts}${NC}${GREEN})${NC}"
        fi
    fi
}

# Ensure the given models exist inside the fast-storage Docker volume.
# Usage: ensure_model_in_volume <gguf-file> [more-gguf-files...]
# On Windows hosts, bind mounts go through Docker Desktop's 9p bridge, making
# the engine's model load (every cold start) several times slower than the
# named volume, which lives on the Docker VM's native disk. The host copies in
# MODEL_STORAGE_DIR remain the download cache and source of truth; this copies
# them into the volume once per model (size-verified, interruption-safe via a
# .part rename). Exactly the given files are kept in the volume — anything
# else is pruned so hidden VM disk usage stays bounded.
# Requires $LLAMA_IMAGE to be present (caller pulls it first).
ensure_model_in_volume() {
    local files=("$@") f
    [ "${#files[@]}" -gt 0 ] || return 1
    for f in "${files[@]}"; do
        [ -f "$MODEL_STORAGE_DIR/$f" ] || return 1
    done

    docker volume create "$MODEL_VOLUME_NAME" >/dev/null 2>&1 || true

    # One container call lists current volume contents as "name size" lines.
    local vol_listing
    vol_listing=$(docker run --rm --entrypoint /bin/sh -v "$MODEL_VOLUME_NAME:/vol" "$LLAMA_IMAGE" \
        -c 'for p in /vol/*.gguf; do [ -f "$p" ] && printf "%s %s\n" "${p##*/}" "$(stat -c%s "$p")"; done; true' \
        2>/dev/null | tr -d '\r') || vol_listing=""

    local keep_expr="" sync_list="" total_sz=0 host_sz vol_sz
    for f in "${files[@]}"; do
        keep_expr+=" ! -name '$f'"
        host_sz=$(stat -c%s "$MODEL_STORAGE_DIR/$f" 2>/dev/null || echo 0)
        [ "$host_sz" -gt 0 ] || return 1
        vol_sz=$(printf '%s\n' "$vol_listing" | awk -v n="$f" '$1==n{print $2}')
        if [ "${vol_sz:-0}" != "$host_sz" ]; then
            sync_list+=" $f"
            total_sz=$(( total_sz + host_sz ))
        fi
    done

    if [ -z "$sync_list" ]; then
        # Nothing to copy — still prune files no longer wanted (e.g. a draft
        # model after speculative decoding was turned off, or an old model).
        docker run --rm --entrypoint /bin/sh -v "$MODEL_VOLUME_NAME:/vol" "$LLAMA_IMAGE" \
            -c "find /vol -maxdepth 1 -name '*.gguf' $keep_expr -delete" >/dev/null 2>&1 || true
        return 0
    fi

    echo -e "${ICON_GEAR} Syncing model(s) to fast storage volume ${DIM}(one-time per model)...${NC}"
    local _sync_name="ai-coder-model-sync"
    docker rm -f "$_sync_name" >/dev/null 2>&1 || true
    docker run -d --name "$_sync_name" --entrypoint /bin/sh \
        -v "$MODEL_VOLUME_NAME:/vol" \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/src:ro" \
        "$LLAMA_IMAGE" -c "
            find /vol -maxdepth 1 -name '*.gguf' $keep_expr -delete
            for f in $sync_list; do
                rm -f \"/vol/\$f.part\" \"/vol/\$f\"
                cp \"/src/\$f\" \"/vol/\$f.part\" && mv \"/vol/\$f.part\" \"/vol/\$f\" || exit 1
            done
        " >/dev/null || return 1

    local human_total; human_total=$(_human_size "$total_sz")
    while [ -n "$(docker ps -q -f name=^/${_sync_name}$ 2>/dev/null)" ]; do
        local cur
        cur=$(docker exec "$_sync_name" /bin/sh -c "
            tot=0
            for f in $sync_list; do
                if [ -f \"/vol/\$f\" ]; then s=\$(stat -c%s \"/vol/\$f\")
                elif [ -f \"/vol/\$f.part\" ]; then s=\$(stat -c%s \"/vol/\$f.part\")
                else s=0; fi
                tot=\$((tot+s))
            done
            echo \$tot
        " 2>/dev/null | tr -d '\r') || cur=0
        case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
        printf "\r  Synced: %s / %s (%d%%)   " "$(_human_size "$cur")" "$human_total" "$(( cur * 100 / total_sz ))"
        sleep 3
    done
    printf "\r%-60s\r" ""

    local _rc; _rc=$(docker inspect -f '{{.State.ExitCode}}' "$_sync_name" 2>/dev/null | tr -d '\r') || _rc=1
    docker rm "$_sync_name" >/dev/null 2>&1 || true
    if [ "$_rc" != "0" ]; then
        echo -e "${YELLOW}⚠ Model volume sync failed (exit ${_rc}).${NC}"
        return 1
    fi
    echo -e "${ICON_OK} Model(s) cached in fast storage volume."
}

_start_litellm_proxy() {
    local hub_net="$1"
    mkdir -p "$HOME/.ai-coder"
    local config_content; config_content=$(get_litellm_config)
    cat > "$HOME/.ai-coder/litellm_config.yaml" <<EOF
$config_content
EOF
    # on-failure:3 (not always) so a host reboot doesn't resurrect the proxy
    # orphaned without its engine. Port bound to localhost only.
    docker run -d --name "$GLOBAL_PROXY_NAME" --network "$hub_net" -p 127.0.0.1:4000:4000 --restart on-failure:3 \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$HOME/.ai-coder/litellm_config.yaml"):/app/config.yaml:ro" \
        "$LITELLM_IMAGE" --config /app/config.yaml > /dev/null || {
        echo -e "${RED}✘ Failed to start proxy container${NC}"; return 1
    }
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub..."

    docker stop "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        docker stop "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        docker rm   "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    fi

    pull_image_if_missing "$LLAMA_IMAGE" || return 1
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        pull_image_if_missing "$LITELLM_IMAGE" || return 1
    fi

    # Speculative decoding: a small draft model proposes tokens the main
    # model verifies in one pass — typically 1.5-2x generation speed on code.
    local _draft_args=() _vol_files=("$MODEL_FILE")
    if spec_decode_enabled && [ -f "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" ]; then
        _draft_args=(--model-draft "/models/$MODEL_DRAFT_FILE" -ngld 99)
        _vol_files+=("$MODEL_DRAFT_FILE")
        echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}enabled${NC} ${DIM}(draft: ${MODEL_DRAFT_FILE})${NC}"
    fi

    # Model mount: fast Docker volume when enabled (with fallback to the
    # direct host folder mount if the sync fails for any reason).
    local _models_src; _models_src="$(to_host_path "$MODEL_STORAGE_DIR")"
    if [ "$(read_pref "$SETTINGS_FILE" model_volume "$MODEL_VOLUME_DEFAULT")" = "yes" ]; then
        if ensure_model_in_volume "${_vol_files[@]}"; then
            _models_src="$MODEL_VOLUME_NAME"
            echo -e "${ICON_GEAR} Model storage: ${GREEN}fast volume (${MODEL_VOLUME_NAME})${NC}"
        else
            echo -e "${YELLOW}⚠ Falling back to direct host folder mount for models.${NC}"
        fi
    fi

    local _gpus_flag _ts_args=() _cuda_env=()
    _resolve_engine_gpu_args

    local _hub_net="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _hub_net="$HUB_ISOLATED_NET"

    local _port_args=()
    if [ "$(read_pref "$SETTINGS_FILE" expose_host_port no)" = "yes" ]; then
        # Bind to localhost only so the engine is not reachable from the LAN.
        _port_args=(-p 127.0.0.1:8080:8080)
        echo -e "${ICON_GEAR} Engine port: ${GREEN}published on localhost:8080${NC}"
    fi

    local _jinja_args=()
    if [ "${MODEL_JINJA:-true}" = "true" ]; then
        _jinja_args=(--jinja)
        echo -e "${ICON_GEAR} Jinja template: ${GREEN}enabled${NC}"
    else
        echo -e "${ICON_GEAR} Jinja template: ${YELLOW}disabled (model uses non-JSON tool call format)${NC}"
    fi

    # Thinking mode: reasoning models (Qwen3) burn hundreds of tokens before
    # every tool call. MODEL_THINKING=false disables it for snappier turns.
    local _think_args=()
    if [ "${MODEL_THINKING:-true}" = "false" ]; then
        _think_args=(--reasoning-budget 0)
        echo -e "${ICON_GEAR} Thinking mode: ${YELLOW}disabled (--reasoning-budget 0)${NC}"
    fi

    # Repeat penalty is off unless a family conf sets MODEL_REPEAT_PENALTY —
    # it penalizes legitimately repeated tokens (indentation, identifiers,
    # JSON keys in tool calls) and is a known cause of malformed tool calls.
    local _rp_args=()
    if [ -n "${MODEL_REPEAT_PENALTY:-}" ]; then
        _rp_args=(--repeat-penalty "$MODEL_REPEAT_PENALTY" --repeat-last-n "${MODEL_REPEAT_LAST_N:-128}")
        echo -e "${ICON_GEAR} Repeat penalty: ${YELLOW}${MODEL_REPEAT_PENALTY}${NC}"
    fi

    # --cache-reuse: agent conversations grow by appending, so reusing KV
    # cache chunks across requests avoids reprocessing the whole prompt each
    # turn — a large time-to-first-token win in agent loops.
    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$_hub_net" --gpus "$_gpus_flag" --restart on-failure:3 \
        "${_port_args[@]}" "${_cuda_env[@]}" \
        -v "${_models_src}:/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port 8080 \
        --parallel "$MODEL_MAX_SLOTS" -ngl 99 -c "$MODEL_CTX_SIZE" --flash-attn on \
        -ctk "${MODEL_KV_TYPE:-q8_0}" -ctv "${MODEL_KV_TYPE:-q8_0}" \
        --batch-size 4096 --defrag-thold 0.1 \
        --cache-reuse "${MODEL_CACHE_REUSE:-256}" \
        "${_draft_args[@]}" "${_think_args[@]}" "${_rp_args[@]}" "${_jinja_args[@]}" "${_ts_args[@]}" > /dev/null || {
        echo -e "${RED}✘ Failed to start engine container${NC}"; return 1
    }

    write_pref "$STATE_FILE" engine_gpu_mode "${GPU_MODE:-multi}"
    write_pref "$STATE_FILE" engine_model "${MODEL_FILE:-}"
    write_pref "$STATE_FILE" engine_ctx "${MODEL_CTX_SIZE:-}"
    write_pref "$STATE_FILE" engine_expose "$(read_pref "$SETTINGS_FILE" expose_host_port no)"
    write_pref "$STATE_FILE" engine_net "${NETWORK_INTERNAL:-false}"
    write_pref "$STATE_FILE" engine_mvol "$(read_pref "$SETTINGS_FILE" model_volume "$MODEL_VOLUME_DEFAULT")"
    local _spec_state=no; [ "${#_draft_args[@]}" -gt 0 ] && _spec_state=yes
    write_pref "$STATE_FILE" engine_spec "$_spec_state"

    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        _start_litellm_proxy "$_hub_net" || return 1
    fi
}

# Sets WORKBENCH_STARTED_BY_US so the caller's cleanup only stops containers
# this session actually started (not one shared with a concurrent session).
ensure_workbench_running() {
    WORKBENCH_STARTED_BY_US=false
    if [ -n "$(docker ps -q -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        return 0
    fi
    WORKBENCH_STARTED_BY_US=true
    if [ -n "$(docker ps -aq -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        docker start "$WORKBENCH" >/dev/null 2>&1 || return 1
        return 0
    fi
    start_workbench
}

# --- [ ABSTRACT HOOKS ] -------------------------------------------------------
# To be overridden by child scripts

get_litellm_config() {
    echo "model_list:
  - model_name: \"*\"
    litellm_params:
      model: openai/local
      custom_llm_provider: openai
      api_base: http://$GLOBAL_ENGINE_NAME:8080/v1
      api_key: sk-1234
      timeout: 600
      stream_timeout: 600

litellm_settings:
  request_timeout: 600
  drop_params: true
  num_retries: 0"
}

build_image() {
    echo -e "${RED}✘ build_image() not implemented in child${NC}"; return 1
}

configure_workbench() {
    : # Default: do nothing
}

start_workbench() {
    echo -e "${RED}✘ start_workbench() not implemented in child${NC}"; return 1
}

execute_tool() {
    echo -e "${RED}✘ execute_tool() not implemented in child${NC}"; return 1
}

# --- [ COMMANDS ] -------------------------------------------------------------

# Arm a detached watcher that stops the warm hub after <idle-minutes> unless
# something used it in the meantime. Disarming works through the
# hub_idle_since stamp in state.conf: every launch clears it, and every
# session exit re-arms with a fresh stamp — so at its deadline the watcher
# only fires if its own stamp is still current AND no spokes are running.
# Best-effort by design: if the watcher dies (e.g. terminal closed), the hub
# simply stays warm, which was the behaviour before the timeout existed.
schedule_hub_idle_stop() {
    local idle_min="$1"
    local stamp; stamp=$(date +%s)
    write_pref "$STATE_FILE" hub_idle_since "$stamp"
    nohup bash -c "
        sleep $(( idle_min * 60 ))
        cur=\$(grep '^hub_idle_since=' '$STATE_FILE' 2>/dev/null | cut -d= -f2-)
        [ \"\$cur\" = '$stamp' ] || exit 0
        [ -n \"\$(docker ps -q --filter 'name=^/${WORKBENCH_PREFIX}-' 2>/dev/null)\" ] && exit 0
        docker stop '$GLOBAL_ENGINE_NAME' '$GLOBAL_PROXY_NAME' >/dev/null 2>&1
        docker rm   '$GLOBAL_ENGINE_NAME' '$GLOBAL_PROXY_NAME' >/dev/null 2>&1
        sed -i '/^hub_idle_since=/d' '$STATE_FILE' 2>/dev/null
    " >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

stop_hub() {
    echo -e "${CYAN}◈ Shutting down Hub...${NC}"
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    echo -e "${ICON_OK} Hub stopped."
}

teardown() {
    echo -e "${CYAN}Tearing down Hub & Project Spokes...${NC}"
    local _running; _running=$(docker ps -q  --filter "name=^/${WORKBENCH_PREFIX}-" 2>/dev/null || true)
    local _all;     _all=$(docker ps -aq --filter "name=^/${WORKBENCH_PREFIX}-" 2>/dev/null || true)
    # shellcheck disable=SC2086
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" $( [ -n "$_running" ] && echo "$_running") 2>/dev/null || true
    # shellcheck disable=SC2086
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" $( [ -n "$_all" ]     && echo "$_all")     2>/dev/null || true
    docker network rm "$HUB_NETWORK" "$HUB_ISOLATED_NET" 2>/dev/null || true
}

handle_command() {
    cmd="${1:-}"
    case "$cmd" in
        --build-only)
            BUILD_ONLY=true
            ;;
        "")
            ;;
        *)
            echo -e "${RED}Unknown command: ${cmd}${NC}"
            echo "Run: $0 --help"
            exit 1
            ;;
    esac
}
