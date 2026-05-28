#!/bin/bash
# ==============================================================================
# AI-CODER-CORE.SH | Shared Infrastructure Library
# ==============================================================================
set -euo pipefail

# --- [ GLOBAL CONFIGURATION ] -------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PACKAGES_DIR="$(dirname "$SCRIPT_DIR")/packages"
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
HUB_NETWORK="ai-engineering-net"
HUB_ISOLATED_NET="ai-engineering-isolated"
NETWORK_INTERNAL=false
NEEDS_LITELLM_PROXY=false
BUILD_ONLY=false
WORKBENCH_PREFIX="coder"
LITELLM_IMAGE="ghcr.io/berriai/litellm:main-latest"
LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
# If DOWNLOAD_PROXY was not set in the environment, fall back to the saved preference file.
PROXY_PREF_FILE="$HOME/.ai-coder-proxy"
if [ -z "$DOWNLOAD_PROXY" ] && [ -f "$PROXY_PREF_FILE" ]; then
    DOWNLOAD_PROXY=$(cat "$PROXY_PREF_FILE" 2>/dev/null || true)
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
            pkg=$(printf '%s' "$pkg"  | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^pip://')
            [[ "$pkg" =~ ^# ]] && continue
            [ -z "$pkg" ] && continue
            net_req=$(printf '%s' "${net_req:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$net_req" = "online" ] && [ "${NETWORK_INTERNAL:-false}" = "true" ] && continue
            key=$(printf '%s' "$key"  | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            cmd=$(printf '%s' "$cmd"  | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            args_str=$(printf '%s' "$args_str" | tr -d '\r' | \
                sed "s|{workspace}|$workspace|g" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Build JSON array from space-delimited tokens
            local arr=() a
            for a in $args_str; do arr+=("\"$a\""); done
            local args_json="[]"
            if [ "${#arr[@]}" -gt 0 ]; then
                local joined; joined=$(printf ',%s' "${arr[@]}"); args_json="[${joined:1}]"
            fi
            # Build optional env JSON from 5th field (comma-separated name=value or bare name pairs)
            # Bare names expand from the calling environment; name={workspace} substitutes the workspace path.
            env_vars_str=$(printf '%s' "${env_vars_str:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*//')
            local env_json="" env_parts=() env_name env_override
            if [ -n "$env_vars_str" ]; then
                IFS=',' read -ra env_names <<< "$env_vars_str"
                for env_name in "${env_names[@]}"; do
                    env_name=$(printf '%s' "$env_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [ -z "$env_name" ] && continue
                    # Support NAME=value syntax in the 5th field (with {workspace} substitution)
                    if [[ "$env_name" == *=* ]]; then
                        local ev_key ev_val
                        ev_key="${env_name%%=*}"
                        ev_val="${env_name#*=}"
                        ev_val=$(printf '%s' "$ev_val" | sed "s|{workspace}|$workspace|g")
                        env_parts+=("\"$ev_key\": \"$ev_val\"")
                    else
                        local env_val="${!env_name:-}"
                        env_parts+=("\"$env_name\": \"$env_val\"")
                    fi
                done
                if [ "${#env_parts[@]}" -gt 0 ]; then
                    local env_joined; env_joined=$(printf ',%s' "${env_parts[@]}")
                    # OpenCode uses "environment"; standard Claude/Gemini format uses "env"
                    local env_field="env"
                    [ "$mode" = "opencode" ] && env_field="environment"
                    env_json=", \"$env_field\": {${env_joined:1}}"
                fi
            fi
            if [ "$mode" = "opencode" ]; then
                # opencode requires command as a JSON array (cmd + args merged) and an "enabled" key
                local oc_arr=("\"$cmd\"") oc_a
                for oc_a in "${arr[@]}"; do oc_arr+=("$oc_a"); done
                local oc_joined; oc_joined=$(printf ',%s' "${oc_arr[@]}"); local oc_cmd_json="[${oc_joined:1}]"
                entries+=("    \"$key\": {\"type\": \"local\", \"command\": $oc_cmd_json, \"enabled\": true$env_json}")
            else
                entries+=("    \"$key\": {\"command\": \"$cmd\", \"args\": $args_json$env_json}")
            fi
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

# Read a key=value entry from a preference file. Returns the value, or $default if missing.
read_pref() {
    local file="$1" key="$2" default="${3:-}"
    if [ -f "$file" ]; then
        local val; val=$(grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-)
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

# Resolve proxy hostname to IP so Docker build containers can reach it.
# getent is Linux-only; fall back to nslookup (available in Git Bash + WSL).
resolve_proxy_to_ip() {
    local proxy_url="$1"
    local host; host=$(echo "$proxy_url" | sed 's|.*://||;s|:.*||')
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup "$host" 2>/dev/null | tr -d '\r' | awk '/^Address:/{ip=$2} END{print ip}' | head -1)
    fi
    if [ -n "$ip" ]; then
        echo "$proxy_url" | sed "s|$host|$ip|"
    else
        echo "$proxy_url"
    fi
}

# --- [ GIT IDENTITY ] ---------------------------------------------------------

GIT_IDENTITY_FILE="$HOME/.ai-coder-gitconfig"

# Load or prompt for git user identity, then store it for future runs.
# Sets GIT_USER_EMAIL and GIT_USER_NAME in the calling environment.
ensure_git_identity() {
    local git_email; git_email=$(read_pref "$GIT_IDENTITY_FILE" email)
    local git_name;  git_name=$(read_pref  "$GIT_IDENTITY_FILE" name)
    [ -z "$git_email" ] && git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$git_name"  ] && git_name=$(git config  --global user.name  2>/dev/null || true)
    GIT_USER_EMAIL="${git_email:-}"
    GIT_USER_NAME="${git_name:-}"
}

# --- [ NETWORK CONFIG ] -------------------------------------------------------

# Load or prompt for network isolation preference, then store it for future runs.
# Sets NETWORK_INTERNAL in the calling environment.
ensure_network_config() {
    local isolated_net; isolated_net=$(read_pref "$HOME/.ai-coder-netconfig" isolated no)
    [ "$isolated_net" = "yes" ] && NETWORK_INTERNAL=true || true
}

# Load or prompt for GPU mode preference, then store it for future runs.
# Sets GPU_MODE in the calling environment ("multi" or "single").
# Silently skips the prompt when only one GPU is present.
ensure_gpu_config() {
    GPU_MODE=$(read_pref "$HOME/.ai-coder-gpuconf" gpu_mode multi)
}

# Sets MODEL_CTX_LEVEL (and derives MODEL_CTX_SIZE) from the saved preference.
# Falls back to the default defined in ai-coder-model.conf when no pref is saved.
ensure_ctx_config() {
    local _level; _level=$(read_pref "$HOME/.ai-coder-ctxconfig" ctx_level "")
    [ -n "$_level" ] && MODEL_CTX_LEVEL="$_level"
    # Re-derive MODEL_CTX_SIZE from the (possibly updated) level.
    case "${MODEL_CTX_LEVEL:-128k}" in
        4k)   MODEL_CTX_SIZE=4096   ;;
        8k)   MODEL_CTX_SIZE=8192   ;;
        16k)  MODEL_CTX_SIZE=16384  ;;
        32k)  MODEL_CTX_SIZE=32768  ;;
        64k)  MODEL_CTX_SIZE=65536  ;;
        128k) MODEL_CTX_SIZE=131072 ;;
        256k) MODEL_CTX_SIZE=262144 ;;
        *)    MODEL_CTX_SIZE=131072 ;;
    esac
}

# Write a ~/.gitconfig-container file that gets mounted into containers as
# /root/.gitconfig so git commands in any repo (including newly init'd ones)
# pick up the correct author identity.
ensure_container_gitconfig() {
    local gitcfg="$HOME/.gitconfig-container"
    if [ -n "${GIT_USER_EMAIL:-}" ] || [ -n "${GIT_USER_NAME:-}" ]; then
        cat > "$gitcfg" <<GITCFG
[user]
    email = ${GIT_USER_EMAIL:-developer@localhost}
    name = ${GIT_USER_NAME:-Developer}
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
    [ -n "${GIT_USER_NAME:-}" ] && echo -e "${ICON_OK} Git identity: ${CYAN}${GIT_USER_NAME} <${GIT_USER_EMAIL}>${NC}"
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
                start "" "$DOCKER_BIN" || { echo -e "${RED}✘ Failed to start Docker${NC}"; return 1; }
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

# Sets MODEL_FILE and MODEL_TIER based on the supplied VRAM amount in GB.
select_model_for_vram() {
    local vram="${1:-0}"
    if   [ "$vram" -ge "$MODEL_TIER_32GB_MIN" ]; then MODEL_FILE="$MODEL_32GB_FILE"; MODEL_TIER="32GB-tier"
    elif [ "$vram" -ge "$MODEL_TIER_24GB_MIN" ]; then MODEL_FILE="$MODEL_24GB_FILE"; MODEL_TIER="24GB-tier"
    elif [ "$vram" -ge "$MODEL_TIER_16GB_MIN" ]; then MODEL_FILE="$MODEL_16GB_FILE"; MODEL_TIER="16GB-tier"
    elif [ "$vram" -ge "$MODEL_TIER_12GB_MIN" ]; then MODEL_FILE="$MODEL_12GB_FILE"; MODEL_TIER="12GB-tier"
    else                                               MODEL_FILE="$MODEL_8GB_FILE";  MODEL_TIER="8GB-tier"
    fi
}

# Download a URL to a local path. Selects the best available tool and handles proxy.
_download_file() {
    local url="$1" dest="$2"
    local win_curl=""
    [ "$IS_WSL" = "true" ] && win_curl=$(command -v curl.exe 2>/dev/null || true)
    local http_proxy=""
    [ -n "${DOWNLOAD_PROXY:-}" ] && http_proxy=$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')

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

# Show a file-size progress ticker for a background download PID, then wait for it.
# Cleans up a partial file if the download fails.
_await_download() {
    local dl_pid="$1" file_path="$2"
    while kill -0 "$dl_pid" 2>/dev/null; do
        local sz; sz=$(stat -c%s "$file_path" 2>/dev/null || echo 0)
        printf "\r  Downloaded: %-12s" "$(numfmt --to=iec-i --suffix=B "$sz")"
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

download_model() {
    if [ -n "${MODEL_FILE:-}" ] && [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        return 0
    fi

    [ -z "${MODEL_FILE:-}" ] && select_model_for_vram "${VRAM_GB:-0}"

    local model_url model_hint
    case "$MODEL_FILE" in
        "$MODEL_32GB_FILE") model_url="$MODEL_32GB_URL"; model_hint="$MODEL_32GB_DESC" ;;
        "$MODEL_24GB_FILE") model_url="$MODEL_24GB_URL"; model_hint="$MODEL_24GB_DESC" ;;
        "$MODEL_16GB_FILE") model_url="$MODEL_16GB_URL"; model_hint="$MODEL_16GB_DESC" ;;
        "$MODEL_12GB_FILE") model_url="$MODEL_12GB_URL"; model_hint="$MODEL_12GB_DESC" ;;
        "$MODEL_8GB_FILE")  model_url="$MODEL_8GB_URL";  model_hint="$MODEL_8GB_DESC"  ;;
        *) echo -e "${RED}✘ Unsupported target model: $MODEL_FILE${NC}"; return 1 ;;
    esac

    [ -z "$model_url" ] && { echo -e "${RED}✘ Missing download URL for $MODEL_FILE${NC}"; return 1; }

    local model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"
    echo -e "${ICON_GEAR} Downloading ${model_hint}..."
    echo -e "${CYAN}Downloading to: $model_path${NC}"
    [ -n "${DOWNLOAD_PROXY:-}" ] && echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"

    _download_file "$model_url" "$model_path" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
    echo -e "${GREEN}✔ Model downloaded successfully${NC}"
}

detect_model() {
    local vram_list; vram_list=$($SMI --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null) || {
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
    
    select_model_for_vram "$VRAM_GB"
    echo -e "${ICON_GEAR} Model Tier: ${BOLD}${MODEL_TIER}${NC}"
    echo -e "${ICON_GEAR} Tier Model: ${CYAN}${MODEL_FILE}${NC}"
    
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

# --- [ WORKBENCH HELPERS ] ----------------------------------------------------

build_standard_image() {
    # Args: <dockerfile-name> <apt-pkgs> <pm-proxy-cmds> <install-cmds>
    # Handles base-image pull, dockerfile generation, and docker build.
    local df_name="$1" apt_pkgs="$2" pm_proxy_cmds="$3" install_cmds="$4"

    if [ -n "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]; then return 0; fi

    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        if [ -n "${DOWNLOAD_PROXY:-}" ]; then
            pull_base_image_via_proxy "$BASE_IMAGE" "$DOWNLOAD_PROXY" || return 1
        else
            docker pull "$BASE_IMAGE" || { echo -e "${RED}✘ Base image pull failed${NC}"; return 1; }
        fi
    fi

    local proxy_args=()
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local build_proxy; build_proxy=$(resolve_proxy_to_ip "$DOWNLOAD_PROXY")
        proxy_args=(--build-arg "PROXY_URL=$build_proxy")
    fi

    cat > "$LOCAL_STACK_DIR/$df_name" <<DOCKERFILE
FROM $BASE_IMAGE
ARG PROXY_URL
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
ENV http_proxy=\${PROXY_URL} https_proxy=\${PROXY_URL} HTTP_PROXY=\${PROXY_URL} HTTPS_PROXY=\${PROXY_URL} \
    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1
${pm_proxy_cmds}
${install_cmds}
DOCKERFILE

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" \
        -f "$(to_host_path "$LOCAL_STACK_DIR")/$df_name" \
        "$(to_host_path "$LOCAL_STACK_DIR")" || {
        echo -e "${RED}✘ Docker build failed${NC}"; return 1
    }
}

exec_in_container() {
    # Usage: exec_in_container [extra docker exec flags...] <container> <cmd> [args...]
    # Handles winpty on Git Bash automatically.
    # Explicitly set PATH so npm/pip global bins are found regardless of shell init.
    local cmd_args=(docker exec -it -w "/$WORKSPACE_DIR" -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@")
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
    docker run -d --name "$WORKBENCH" --network "$wb_network" --privileged \
        -e "http_proxy=${_wb_http_proxy}" -e "https_proxy=${_wb_http_proxy}" \
        -e "HTTP_PROXY=${_wb_http_proxy}" -e "HTTPS_PROXY=${_wb_http_proxy}" \
        -e "no_proxy=$no_proxy_hosts" -e "NO_PROXY=$no_proxy_hosts" \
        -v "$(to_host_path "$(pwd)"):/$WORKSPACE_DIR" \
        --workdir "/$WORKSPACE_DIR" \
        "${extra_flags[@]}" \
        "$IMAGE_NAME" /bin/bash -c "$entrypoint" > /dev/null
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub..."
    docker stop "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" 2>/dev/null || true
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        docker stop "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        docker rm   "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    fi

    local images_to_pull=("$LLAMA_IMAGE")
    [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ] && images_to_pull+=("$LITELLM_IMAGE")
    for img in "${images_to_pull[@]}"; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            echo -e "${CYAN}  Pulling $img ...${NC}"
            docker pull "$img" || { echo -e "${RED}✘ Failed to pull $img${NC}"; return 1; }
        fi
    done

    # GPU selection: honour GPU_MODE set by ensure_gpu_config / ai-coder-model.conf.
    # "single" exposes only GPU 0 to the container; "multi" exposes all GPUs and
    # passes --tensor-split so llama.cpp distributes compute (not just VRAM) across
    # every card. Without --tensor-split, llama.cpp uses all VRAM but runs all
    # matrix multiplications on GPU 0 only.
    local _gpus_flag="all"
    local _ts_args=()
    local _cuda_env=()
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
        # Also set CUDA_VISIBLE_DEVICES so llama.cpp only sees GPU 0 even if
        # Docker's --gpus device=0 flag doesn't fully restrict access (e.g.
        # Docker Desktop / WSL2 passthrough quirks).
        _cuda_env=(-e CUDA_VISIBLE_DEVICES=0)
        echo -e "${ICON_GEAR} GPU Mode: ${YELLOW}Single (GPU 0 only)${NC}"
    else
        local _vram_raw; _vram_raw=$($SMI --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null) || true
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

    # When isolation is active, start Hub containers directly on the isolated
    # network so they have no internet access. Otherwise use the standard hub network.
    local _hub_net="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _hub_net="$HUB_ISOLATED_NET"

    local _port_args=()
    if [ "$(read_pref "$HOME/.ai-coder-portconfig" expose_host_port no)" = "yes" ]; then
        _port_args=(-p 8080:8080)
        echo -e "${ICON_GEAR} Engine port: ${GREEN}published on localhost:8080${NC}"
    fi

    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$_hub_net" --gpus "$_gpus_flag" --restart on-failure:3 \
        "${_port_args[@]}" "${_cuda_env[@]}" \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port 8080 \
        --parallel "$MODEL_MAX_SLOTS" -ngl 99 -c "$MODEL_CTX_SIZE" --flash-attn on \
        -ctk "${MODEL_KV_TYPE:-q8_0}" -ctv "${MODEL_KV_TYPE:-q8_0}" \
        --repeat-penalty 1.1 --repeat-last-n 128 \
        "${_ts_args[@]}" > /dev/null || {
        echo -e "${RED}✘ Failed to start engine container${NC}"; return 1
    }

    # Record the GPU mode used so ai-coder can detect changes and restart.
    printf 'gpu_mode=%s\nmodel=%s\n' "${GPU_MODE:-multi}" "${MODEL_FILE:-}" \
        > "$HOME/.ai-coder-engine-state"

    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        mkdir -p "$HOME/.ai-coder"
        local config_content; config_content=$(get_litellm_config)
        cat > "$HOME/.ai-coder/litellm_config.yaml" <<EOF
$config_content
EOF
        docker run -d --name "$GLOBAL_PROXY_NAME" --network "$_hub_net" -p 4000:4000 --restart always \
            -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
            -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
            -v "$(to_host_path "$HOME/.ai-coder/litellm_config.yaml"):/app/config.yaml:ro" \
            "$LITELLM_IMAGE" --config /app/config.yaml > /dev/null || {
            echo -e "${RED}✘ Failed to start proxy container${NC}"; return 1
        }
    fi
}

ensure_workbench_running() {
    if [ -n "$(docker ps -q -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        return 0
    fi
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

stop_hub() {
    echo -e "${CYAN}◈ Shutting down Hub...${NC}"
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    echo -e "${ICON_OK} Hub stopped."
}

teardown() {
    echo -e "${CYAN}Tearing down Hub & Project Spokes...${NC}"
    local _running; _running=$(docker ps -q  --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null || true)
    local _all;     _all=$(docker ps -aq --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null || true)
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
        spawn|"")
            ;;
        *)
            echo -e "${RED}Unknown command: ${cmd}${NC}"
            echo "Run: $0 --help"
            exit 1
            ;;
    esac
}
