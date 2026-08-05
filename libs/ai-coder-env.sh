#!/bin/bash
# ==============================================================================
# AI-CODER-ENV.SH | Path/Shell Utilities, Preference I/O, MCP JSON Generation
# Sourced by ai-coder-core.sh after global config and environment detection are
# set up, so every function here can rely on SCRIPT_DIR, PACKAGES_DIR,
# SETTINGS_FILE, STATE_FILE, IS_WSL/IS_GITBASH, and the color vars from
# ai-coder-graphics.sh.
# ==============================================================================

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
            awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 != "" && substr($1,1,4) != "pip:") printf "%s ", $1}' || true
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
            }' || true
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

# Acquire a simple mkdir-based spinlock — mkdir is atomic on both WSL and Git
# Bash, making it safe against concurrent ai-coder sessions racing on the same
# shared resource (a preference file, the Hub singleton container, a
# per-project workbench container). Best-effort, not a hard mutual-exclusion
# guarantee: gives up and proceeds anyway once max_wait iterations pass,
# rather than hang forever on a lock dir orphaned by a killed session.
# Usage: acquire_lock <lock_dir> [sleep_interval] [max_wait_iterations]
acquire_lock() {
    local lock_dir="$1" interval="${2:-0.2}" max_wait="${3:-150}"
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep "$interval"
        waited=$((waited + 1))
        [ "$waited" -gt "$max_wait" ] && break
    done
}

release_lock() {
    rmdir "$1" 2>/dev/null || true
}

# True when a container with this exact name is currently running (not merely
# present-but-stopped). Wraps the `docker ps -q -f name=^/<name>$` idiom used
# throughout the launch/status/lifecycle code so call sites read as intent.
container_running() {
    [ -n "$(docker ps -q -f "name=^/${1}$" 2>/dev/null)" ]
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
# STATE_FILE/SETTINGS_FILE are global (not per-project), so concurrent
# ai-coder sessions for unrelated projects can call this on the same file at
# once. A lock (see acquire_lock) plus a PID-unique temp file prevent one
# session's read-modify-write from clobbering another's.
write_pref() {
    local file="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$file")"

    local _lock_dir="${file}.lock"
    acquire_lock "$_lock_dir" 0.1 100

    local _tmp="${file}.tmp.$$"
    if [ -f "$file" ]; then
        grep -v "^${key}=" "$file" > "$_tmp" 2>/dev/null || true
    else
        : > "$_tmp"
    fi
    [ -n "$value" ] && printf '%s=%s\n' "$key" "$value" >> "$_tmp"
    mv "$_tmp" "$file"

    release_lock "$_lock_dir"
}

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
