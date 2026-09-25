#!/bin/bash
# ==============================================================================
# AI-CODER-ENV.SH | Path/Shell Utilities, Preference I/O, MCP JSON Generation
# Sourced by ai-coder-core.sh after global config and environment detection are
# set up, so every function here can rely on SCRIPT_DIR, PACKAGES_DIR,
# SETTINGS_FILE, STATE_FILE, IS_WSL/IS_GITBASH, and the color vars from
# ai-coder-graphics.sh.
# ==============================================================================

# Convert a host path to the form Docker bind mounts expect on this platform:
# WSL uses the /mnt/... path as-is; Git Bash converts to a Windows path
# (cygpath -m); everything else (plain POSIX) gets the // prefix.
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

# Make <dir> usable for config writes: create it if missing, and reclaim
# ownership (sudo chown) if a Docker root process left it root-owned.
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

# Trim surrounding whitespace and CR from one pipe-delimited manifest field.
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

# Resolve comma-separated manifest env specs to NAME=value lines:
# "NAME"        → expands $NAME from the calling environment
# "NAME=value"  → literal value (supports {workspace} substitution)
_mcp_env_pairs() {
    local env_vars_str="$1" workspace="$2" env_name env_names
    [ -z "$env_vars_str" ] && return
    IFS=',' read -ra env_names <<< "$env_vars_str"
    for env_name in "${env_names[@]}"; do
        env_name=$(_mcp_trim "$env_name")
        [ -z "$env_name" ] && continue
        if [[ "$env_name" == *=* ]]; then
            printf '%s\n' "$env_name" | sed "s|{workspace}|$workspace|g"
        else
            printf '%s=%s\n' "$env_name" "${!env_name:-}"
        fi
    done
}

# Walk pipe-delimited MCP server manifests and call <callback> once for every
# server to register this launch, as:
#   <callback> <key> <command> <args> <env-specs> <workspace-path>
# with each field trimmed and {workspace} in args replaced by <workspace-path>.
# File format: npm-pkg | server-key | command | arg1 arg2 ... | ENV_SPECS | net
# The optional 5th field lists env specs (see _mcp_env_pairs). The optional
# 6th field: set to "online" to skip the server when NETWORK_INTERNAL=true.
# Usage: _mcp_each_server <callback> <workspace-path> <file1> [file2 ...]
_mcp_each_server() {
    local callback="$1" workspace="$2"
    shift 2
    local file pkg key cmd args_str env_vars_str net_req
    for file in "$@"; do
        [ -f "$file" ] || continue
        while IFS='|' read -r pkg key cmd args_str env_vars_str net_req; do
            pkg=$(_mcp_trim "$pkg"); pkg="${pkg#pip:}"
            [[ "$pkg" =~ ^# ]] && continue
            [ -z "$pkg" ] && continue
            [ "$(_mcp_trim "${net_req:-}")" = "online" ] && [ "${NETWORK_INTERNAL:-false}" = "true" ] && continue
            args_str=$(printf '%s' "$args_str" | tr -d '\r' | \
                sed "s|{workspace}|$workspace|g;s/^[[:space:]]*//;s/[[:space:]]*$//")
            "$callback" "$(_mcp_trim "$key")" "$(_mcp_trim "$cmd")" "$args_str" \
                "$(_mcp_trim "${env_vars_str:-}")" "$workspace"
        done < "$file"
    done
}

# _mcp_each_server callback printing one mcpServers JSON entry per line, in
# the format named by _mcp_mode (a local of make_mcp_servers_json):
# standard (Claude/Gemini): {"command": "...", "args": [...], "env": {...}}
# opencode:                 {"type": "local", "command": [...], "enabled": true, "environment": {...}}
_mcp_json_entry() {
    local key="$1" cmd="$2" args_str="$3" env_specs="$4" workspace="$5"
    local arr=() a
    for a in $args_str; do arr+=("\"$(_mcp_json_escape "$a")\""); done

    local env_json="" env_parts=() pair
    while IFS= read -r pair; do
        env_parts+=("\"${pair%%=*}\": \"$(_mcp_json_escape "${pair#*=}")\"")
    done < <(_mcp_env_pairs "$env_specs" "$workspace")
    if [ "${#env_parts[@]}" -gt 0 ]; then
        local env_joined; env_joined=$(printf ',%s' "${env_parts[@]}")
        local env_field="env"
        [ "$_mcp_mode" = "opencode" ] && env_field="environment"
        env_json=$(printf ', "%s": {%s}' "$env_field" "${env_joined:1}")
    fi

    if [ "$_mcp_mode" = "opencode" ]; then
        local oc_arr=("\"$cmd\"")
        [ "${#arr[@]}" -gt 0 ] && oc_arr+=("${arr[@]}")
        local oc_joined; oc_joined=$(printf ',%s' "${oc_arr[@]}")
        printf '    "%s": {"type": "local", "command": [%s], "enabled": true%s}\n' \
            "$key" "${oc_joined:1}" "$env_json"
    else
        local args_json="[]"
        if [ "${#arr[@]}" -gt 0 ]; then
            local joined; joined=$(printf ',%s' "${arr[@]}"); args_json="[${joined:1}]"
        fi
        printf '    "%s": {"command": "%s", "args": %s%s}\n' "$key" "$cmd" "$args_json" "$env_json"
    fi
}

# _mcp_each_server callback collecting registered server keys for the
# registration report (report_mcp_registration in ai-coder-core.sh). Prints
# each key on its own line — no JSON emission, so it can't change what gets
# written, only surface what was registered.
_mcp_report_entry() {
    local key="$1"
    printf '%s\n' "$key"
}

# Emit indented, comma-separated mcpServers JSON entries from one or more
# server manifests (file format: see _mcp_each_server).
# Usage: make_mcp_servers_json <workspace-path> <mode> <file1> [file2 ...]
# mode: "standard" (Claude / Gemini format) or "opencode"
make_mcp_servers_json() {
    local workspace="$1" _mcp_mode="${2:-standard}"
    shift 2
    _mcp_each_server _mcp_json_entry "$workspace" "$@" | sed '$!s/$/,/'
}

# Print (one path per line) the server manifests an agent registers this
# launch: core servers (mcp-common.txt), optional extras (mcp-extra.txt, only
# when enabled via --setup), and the agent's own server file.
# Usage: mcp_manifest_files <agent-mcp-file-basename>
mcp_manifest_files() {
    echo "$PACKAGES_DIR/mcp-common.txt"
    if [ "$(read_setting mcp_extras)" = "yes" ]; then
        echo "$PACKAGES_DIR/mcp-extra.txt"
    fi
    echo "$PACKAGES_DIR/$1"
}

# Emit the mcpServers JSON entries an agent should register this launch
# (the manifests from mcp_manifest_files).
# Usage: make_agent_mcp_json <workspace-path> <mode> <agent-mcp-file-basename>
make_agent_mcp_json() {
    local workspace="$1" mode="$2" files=()
    mapfile -t files < <(mcp_manifest_files "$3")
    make_mcp_servers_json "$workspace" "$mode" "${files[@]}"
}

# First line of every instructions file render_agent_prompt writes. It marks
# the file as ai-coder's, so a same-named file the user wrote themselves
# (e.g. their own ~/.gemini-config/GEMINI.md) is never overwritten or deleted.
AGENT_PROMPT_MARKER="<!-- ai-coder: generated each launch from prompts/ in the ai-coder install -->"

# Print the largest reply to let a tool request: the family's MODEL_MAX_OUTPUT,
# capped at a quarter of the context size so a long reply can't crowd out the
# conversation (tools reserve their output limit out of the context window).
# Prints nothing when the family doesn't set one — callers keep their default.
agent_max_output_tokens() {
    [ -n "${MODEL_MAX_OUTPUT:-}" ] || return 0
    local _cap=$(( ${MODEL_CTX_SIZE:-0} / 4 ))
    if [ "$_cap" -gt 0 ] && [ "$MODEL_MAX_OUTPUT" -gt "$_cap" ]; then
        echo "$_cap"
    else
        echo "$MODEL_MAX_OUTPUT"
    fi
}

# True when the engine keeps past turns' reasoning in the prompt (thinking on
# and MODEL_REASONING_PRESERVE=true) — tools that drop reasoning from the
# history they send back must then be told to keep it.
reasoning_preserved() {
    ! engine_is_sglang && [ "${MODEL_THINKING:-true}" != "false" ] && \
        [ "${MODEL_REASONING_PRESERVE:-false}" = "true" ]
}

# Print the host path of the first of <name>... that exists in the project
# folder ($PWD, mounted as /$WORKSPACE_DIR), or nothing.
# Usage: project_instructions_file CLAUDE.md AGENTS.md
project_instructions_file() {
    local _n
    for _n in "$@"; do
        [ -f "$PWD/$_n" ] && { echo "$PWD/$_n"; return 0; }
    done
    return 0
}

# Write the agent instructions for <tool> to <out-file>: prompts/common.md,
# prompts/offline.md (network isolation only), prompts/families/<family>.md,
# prompts/tools/<tool>.md and prompts/tools/<tool>-mcp-extras.md (MCP extras
# only) — each included when it exists, with {workspace} replaced by the
# container workspace path — then, if given, the project's own instructions
# file under a heading. Every file after common.md continues its bullet list,
# so write them as plain "- " bullets. Kept short on purpose: agents re-send
# it on every request, same reasoning as the mcp-common/mcp-extra split.
# Returns 1 without writing when the agent_prompt setting is off (removing a
# file an earlier launch wrote) or when <out-file> is the user's own file.
# Usage: render_agent_prompt <tool> <out-file> [project-instructions-file]
render_agent_prompt() {
    local tool="$1" out="$2" project_file="${3:-}"
    if [ -f "$out" ] && [ "$(head -n 1 "$out" | tr -d '\r')" != "$AGENT_PROMPT_MARKER" ]; then
        echo -e "${YELLOW}⚠ $out wasn't written by ai-coder — leaving it as is (no ai-coder agent instructions this session).${NC}" >&2
        return 1
    fi
    if [ "$(read_setting agent_prompt)" != "yes" ]; then
        rm -f "$out"
        return 1
    fi
    local parts=("$PROMPTS_DIR/common.md")
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && parts+=("$PROMPTS_DIR/offline.md")
    parts+=("$PROMPTS_DIR/families/${FAMILY_PREF:-}.md" "$PROMPTS_DIR/tools/$tool.md")
    [ "$(read_setting mcp_extras)" = "yes" ] && parts+=("$PROMPTS_DIR/tools/$tool-mcp-extras.md")
    local _ws="/$WORKSPACE_DIR" _f
    _ws="${_ws//&/\\&}"
    {
        echo "$AGENT_PROMPT_MARKER"
        for _f in "${parts[@]}"; do
            [ -f "$_f" ] && sed -e 's/\r$//' -e "s|{workspace}|$_ws|g" "$_f"
        done
        if [ -n "$project_file" ] && [ -f "$project_file" ]; then
            printf '\n# Project instructions (%s)\n\n' "$(basename "$project_file")"
            sed 's/\r$//' "$project_file"
        fi
    } > "$out"
}

# Fetch the commit sha the release branch points at from the GitHub API.
# Echoes empty on any failure (offline, proxy down) — callers treat a blank
# result as "unavailable", matching _fetch_commit_date.
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

# Fetch the commit (checkin) date for a given commit sha, as reported by
# GitHub's commits API, e.g. "2026-09-06T12:34:56Z". Empty on any failure
# (offline, proxy down, unknown sha) — callers treat a blank result as
# "unavailable" rather than an error.
_fetch_commit_date() {
    local sha="$1"
    [ -z "$sha" ] && return
    local api_url="https://api.github.com/repos/ggilman/ai_coder/commits/${sha}"
    local date_re='"date"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"'
    local http_proxy=""
    [ -n "${DOWNLOAD_PROXY:-}" ] && http_proxy=$(resolve_proxy_to_ip "$(echo "$DOWNLOAD_PROXY" | sed "s|^https://|http://|")")
    if command -v curl >/dev/null 2>&1; then
        local curl_args=(-fsSL --connect-timeout 4)
        [ -n "$http_proxy" ] && curl_args+=(--proxy "$http_proxy")
        curl "${curl_args[@]}" "$api_url" 2>/dev/null \
            | grep -oE "$date_re" \
            | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' || true

    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "$http_proxy" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$http_proxy" -e "https_proxy=$http_proxy")
        wget -qO- --timeout=4 "${wget_proxy_args[@]}" "$api_url" 2>/dev/null \
            | grep -oE "$date_re" \
            | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' || true
    fi
}

# Run git inside a directory via a subshell `cd` rather than `git -C <dir>`: with
# MSYS_NO_PATHCONV=1 a Windows-native git.exe gets the raw /d/... path from -C
# and fails with "cannot change to", while bash's own cd resolves it fine.
# Usage: _git_at <dir> <git args...>
_git_at() {
    local dir="$1"; shift
    ( cd "$dir" 2>/dev/null && git "$@" )
}

# True when <dir> is itself a git checkout of this repo (has its own .git), as
# opposed to a tarball install from install.sh/--update — which has no .git and
# may sit inside some unrelated repo, which we ignore. Checkouts take their
# release state from git (origin/release), not from the release_hash recorded in
# state.json, which only tarball installs maintain.
# Usage: _is_git_checkout <dir>
_is_git_checkout() {
    local dir="$1"
    [ -e "$dir/.git" ] && command -v git >/dev/null 2>&1 \
        && _git_at "$dir" rev-parse --git-dir >/dev/null 2>&1
}

# Nudge (at most once a day) when the installed release is behind the
# release branch. Git checkouts compare against their local origin/release
# ref (git is the source of truth there); tarball installs compare the
# release_hash recorded in state.json.
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

    # Git checkout: git is the source of truth. Pushing release from here moves
    # origin/release, so a stored release_hash would go stale and nag forever.
    # Up to date == the release head is already contained in HEAD. Never write
    # release_hash here, and never point at --update (it would clobber the tree).
    if _is_git_checkout "$install_dir"; then
        if ! _git_at "$install_dir" cat-file -e "${remote_hash}^{commit}" 2>/dev/null; then
            echo -e "${YELLOW}◈ New commits on the release branch — run: ${CYAN}git fetch origin${NC}"
        elif ! _git_at "$install_dir" merge-base --is-ancestor "$remote_hash" HEAD 2>/dev/null; then
            echo -e "${YELLOW}◈ Release (${remote_hash:0:10}) has commits not in your checkout — run: ${CYAN}git switch release && git pull --ff-only${NC}"
        fi
        return
    fi

    local local_hash; local_hash=$(read_pref "$STATE_FILE" release_hash "")

    # No recorded hash: first run after install. Save remote hash and assume up to date.
    if [ -z "$local_hash" ]; then
        write_pref "$STATE_FILE" release_hash "$remote_hash"
        local remote_date; remote_date=$(_fetch_commit_date "$remote_hash")
        [ -n "$remote_date" ] && write_pref "$STATE_FILE" release_date "$remote_date"
        return
    fi

    [ "$local_hash" = "$remote_hash" ] && return

    echo -e "${YELLOW}◈ Update available — run: ${CYAN}$(realpath "$install_dir/ai-coder") --update${NC}"
}

# Owner tag written into a lock dir: "<pid> <shell-kind>". PIDs are only
# comparable within one shell kind — a WSL session can't see a Git Bash PID
# (and vice versa), though both can share a lock under $WIN_HOME.
_lock_owner_tag() {
    local kind=linux
    [ "${IS_WSL:-false}" = "true" ] && kind=wsl
    [ "${IS_GITBASH:-false}" = "true" ] && kind=gitbash
    echo "$$ $kind"
}

# Is the session holding <lock_dir> still running? Returns 0 alive, 1 dead,
# 2 unknown (no owner file — a lock from an older version, or one being
# written this instant — or an owner of another shell kind).
_lock_owner_state() {
    local owner pid kind mine
    owner=$(cat "$1/owner" 2>/dev/null) || return 2
    read -r pid kind <<< "$owner"
    [[ "${pid:-}" =~ ^[0-9]+$ ]] || return 2
    mine=$(_lock_owner_tag); [ "$kind" = "${mine#* }" ] || return 2
    kill -0 "$pid" 2>/dev/null && return 0
    return 1
}

# Acquire a mkdir-based lock — mkdir is atomic on both WSL and Git Bash,
# making it safe against concurrent ai-coder sessions racing on the same
# shared resource (a preference file, the Hub singleton container, a
# per-project workbench container, a model download). The holder's PID is
# recorded in <lock_dir>/owner, so a waiter:
#   - takes the lock over at once when its owner has died (crash, kill -9);
#   - keeps waiting, without a time limit, while the owner is still alive —
#     proceeding early would race the very thing the lock guards (Ctrl-C to
#     abandon the wait);
#   - takes it over after max_wait iterations only when the owner can't be
#     checked (see _lock_owner_state).
# wait_msg, if given, is printed once when the lock is found busy.
# Usage: acquire_lock <lock_dir> [sleep_interval] [max_wait_iterations] [wait_msg]
acquire_lock() {
    local lock_dir="$1" interval="${2:-0.2}" max_wait="${3:-150}" wait_msg="${4:-}"
    local waited=0 told=false state failed=0
    until mkdir "$lock_dir" 2>/dev/null; do
        if [ ! -d "$lock_dir" ]; then
            # mkdir failed without the lock existing (parent missing or not
            # writable) — or it was released this instant, which the next
            # mkdir picks up. Persisting: proceed unlocked, as best-effort.
            failed=$((failed + 1))
            [ "$failed" -ge 5 ] && return 0
            continue
        fi
        state=0; _lock_owner_state "$lock_dir" || state=$?
        if [ "$state" -eq 1 ] || { [ "$state" -eq 2 ] && [ "$waited" -ge "$max_wait" ]; }; then
            rm -rf "$lock_dir"
            continue
        fi
        if [ -n "$wait_msg" ] && ! $told; then
            echo -e "${CYAN:-}◈ ${wait_msg}${NC:-}"
            told=true
        fi
        sleep "$interval"
        [ "$state" -eq 2 ] && waited=$((waited + 1))
    done
    _lock_owner_tag > "$lock_dir/owner" 2>/dev/null || true
}

# Release a lock taken by acquire_lock — only when this session still owns
# it, so a session whose lock was taken over never frees the new holder's.
release_lock() {
    [ "$(cat "$1/owner" 2>/dev/null)" = "$(_lock_owner_tag)" ] || return 0
    rm -f "$1/owner"
    rmdir "$1" 2>/dev/null || true
}

# Run <cmd...> up to <attempts> times, sleeping 5s, 15s, 45s, ... between
# tries. Returns the last attempt's exit status. <label> names the operation
# in the retry message (e.g. "Download", "Image pull").
# Usage: retry_with_backoff <attempts> <label> <cmd> [args...]
retry_with_backoff() {
    local _rwb_max="$1" _rwb_label="$2"; shift 2
    [[ "$_rwb_max" =~ ^[1-9][0-9]*$ ]] || _rwb_max=3
    local _rwb_try=1 _rwb_rc
    while true; do
        _rwb_rc=0; "$@" || _rwb_rc=$?
        [ "$_rwb_rc" -eq 0 ] && return 0
        [ "$_rwb_try" -ge "$_rwb_max" ] && return "$_rwb_rc"
        local _rwb_delay=$(( 5 * (3 ** (_rwb_try - 1)) ))
        echo -e "${YELLOW}⚠ ${_rwb_label} failed — retrying (${_rwb_try}/${_rwb_max}) in ${_rwb_delay}s…${NC}"
        sleep "$_rwb_delay"
        _rwb_try=$((_rwb_try + 1))
    done
}

# True when a container with this exact name is currently running (not merely
# present-but-stopped). Wraps the `docker ps -q -f name=^/<name>$` idiom used
# throughout the launch/status/lifecycle code so call sites read as intent.
container_running() {
    [ -n "$(docker ps -q -f "name=^/${1}$" 2>/dev/null)" ]
}

# Read a key from a JSON preference file. Returns the value, or $default when
# the file or key is missing or the file is not valid JSON (e.g. hand-truncated
# or mid-write) - a corrupt file degrades to the default rather than aborting
# the launch. Values are stored as JSON strings; an empty result (absent key
# or parse error) resolves to $default, matching the old empty-means-default.
read_pref() {
    local file="$1" key="$2" default="${3:-}"
    local _jq="${JQ_CMD:-jq}"
    [ -f "$file" ] || { echo "$default"; return 0; }
    local val
    val=$("$_jq" -r --arg k "$key" 'if has($k) then .[$k] else empty end' "$file" 2>/dev/null) || val=""
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$default"
    fi
}

# Write or update a single key in a JSON preference file (values are JSON
# strings). Creates the file and its parent directory if needed. Clears the
# key when value is empty. An existing file that is not valid JSON is replaced
# by a fresh object (degrade, don't abort). STATE_FILE/SETTINGS_FILE are global
# (not per-project), so concurrent ai-coder sessions for unrelated projects can
# call this on the same file at once. A lock (see acquire_lock) plus a
# PID-unique temp file prevent one session's read-modify-write from clobbering
# another's.
write_pref() {
    local file="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$file")"

    # Self-heal: sweep this file's own orphaned .tmp.<pid> leftovers from a
    # session that got killed between mktemp and mv below. That window is
    # normally sub-millisecond, so anything older than a few minutes here is
    # orphaned, not an in-flight write from a concurrent session — safe to
    # delete without a lock. (Broader sweeps — stale lock dirs, other files —
    # are handled by `--doctor`, not on every write_pref call.)
    find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").tmp.*" -mmin +5 -delete 2>/dev/null || true

    local _lock_dir="${file}.lock"
    acquire_lock "$_lock_dir" 0.1 100

    local _tmp="${file}.tmp.$$"
    local _jq="${JQ_CMD:-jq}"
    local _filter
    if [ -z "$value" ]; then
        _filter='del(.[$k])'
    else
        _filter='.[$k] = $v'
    fi
    # Base object: the existing file when it is valid JSON, else an empty
    # object - so a corrupt/missing file is rebuilt (repairing corruption)
    # rather than aborting the write.
    local _base
    if [ -f "$file" ] && "$_jq" empty "$file" >/dev/null 2>&1; then
        _base=$(cat "$file")
    else
        _base='{}'
    fi
    printf '%s' "$_base" | "$_jq" --arg k "$key" --arg v "$value" "$_filter" > "$_tmp" 2>/dev/null || echo '{}' > "$_tmp"
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
