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
BASE_IMAGE="node:20-bullseye-slim"

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
if [ "$IS_WSL" = "true" ]; then
    _win_home=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')
    if [ -n "$_win_home" ]; then
        MODEL_STORAGE_DIR="$(wslpath "$_win_home")/ai-models"
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
    local git_email="" git_name=""

    # Load from persisted file
    if [ -f "$GIT_IDENTITY_FILE" ]; then
        git_email=$(grep '^email=' "$GIT_IDENTITY_FILE" 2>/dev/null | cut -d= -f2-)
        git_name=$(grep  '^name='  "$GIT_IDENTITY_FILE" 2>/dev/null | cut -d= -f2-)
    fi

    # Fall back to host global git config
    [ -z "$git_email" ] && git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$git_name"  ] && git_name=$(git config  --global user.name  2>/dev/null || true)

    # Prompt for anything still missing
    if [ -z "$git_email" ]; then
        echo -ne "${CYAN}◈ Git email for commits: ${NC}"
        read -r git_email
    fi
    if [ -z "$git_name" ]; then
        echo -ne "${CYAN}◈ Git user name for commits: ${NC}"
        read -r git_name
    fi

    # Persist for future runs
    printf 'email=%s\nname=%s\n' "$git_email" "$git_name" > "$GIT_IDENTITY_FILE"

    GIT_USER_EMAIL="$git_email"
    GIT_USER_NAME="$git_name"
}

# --- [ NETWORK CONFIG ] -------------------------------------------------------

# Load or prompt for network isolation preference, then store it for future runs.
# Sets NETWORK_INTERNAL in the calling environment.
ensure_network_config() {
    local isolated_net=""
    local network_config_file="$(pwd)/.ai-coder/netconfig"

    # Load from persisted file
    if [ -f "$network_config_file" ]; then
        isolated_net=$(grep '^isolated=' "$network_config_file" 2>/dev/null | cut -d= -f2-)
    fi

    # Prompt if not yet set
    if [ -z "$isolated_net" ]; then
        echo -ne "${CYAN}◈ Internal network only — block all internet access from containers? [y/N]: ${NC}"
        read -r _ans
        case "${_ans,,}" in
            y|yes) isolated_net="yes" ;;
            *)     isolated_net="no"  ;;
        esac
        printf 'isolated=%s\n' "$isolated_net" > "$network_config_file"
    fi

    [ "$isolated_net" = "yes" ] && NETWORK_INTERNAL=true || true
}

# Load or prompt for GPU mode preference, then store it for future runs.
# Sets GPU_MODE in the calling environment ("multi" or "single").
# Silently skips the prompt when only one GPU is present.
ensure_gpu_config() {
    local gpu_conf_file="$HOME/.ai-coder-gpuconf"
    local stored_mode=""

    if [ -f "$gpu_conf_file" ]; then
        stored_mode=$(grep '^gpu_mode=' "$gpu_conf_file" 2>/dev/null | cut -d= -f2-)
    fi

    if [ -z "$stored_mode" ]; then
        local gpu_count=1
        gpu_count=$($SMI --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | grep -c '.' || echo 1)
        if [ "${gpu_count:-1}" -gt 1 ]; then
            echo -e "${CYAN}◈ ${gpu_count} GPUs detected. Use all GPUs for inference? [Y/n]: ${NC}"
            read -r _ans
            case "${_ans,,}" in
                n|no) stored_mode="single" ;;
                *)    stored_mode="multi"  ;;
            esac
        else
            stored_mode="single"
        fi
        printf 'gpu_mode=%s\n' "$stored_mode" > "$gpu_conf_file"
    fi

    GPU_MODE="$stored_mode"
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
    [ -z "$cur_email" ] && git -C "$(pwd)" config --local user.email "$GIT_USER_EMAIL"
    [ -z "$cur_name"  ] && git -C "$(pwd)" config --local user.name  "$GIT_USER_NAME"
    echo -e "${ICON_OK} Git identity: ${CYAN}${GIT_USER_NAME} <${GIT_USER_EMAIL}>${NC}"
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

download_model() {
    if [ -n "${MODEL_FILE:-}" ] && [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        return 0
    fi

    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}✘ Neither wget nor curl found. Cannot download model.${NC}"
        return 1
    fi

    local model_url
    local model_path
    local model_hint

    if [ -z "${MODEL_FILE:-}" ]; then
        select_model_for_vram "${VRAM_GB:-0}"
    fi

    case "$MODEL_FILE" in
        "$MODEL_32GB_FILE") model_url="$MODEL_32GB_URL"; model_hint="$MODEL_32GB_DESC" ;;
        "$MODEL_24GB_FILE") model_url="$MODEL_24GB_URL"; model_hint="$MODEL_24GB_DESC" ;;
        "$MODEL_16GB_FILE") model_url="$MODEL_16GB_URL"; model_hint="$MODEL_16GB_DESC" ;;
        "$MODEL_12GB_FILE") model_url="$MODEL_12GB_URL"; model_hint="$MODEL_12GB_DESC" ;;
        "$MODEL_8GB_FILE")  model_url="$MODEL_8GB_URL";  model_hint="$MODEL_8GB_DESC" ;;
        *) echo -e "${RED}✘ Unsupported target model: $MODEL_FILE${NC}"; return 1 ;;
    esac

    model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"

    if [ -z "$model_url" ]; then
        echo -e "${RED}✘ Missing download URL for $MODEL_FILE${NC}"; return 1
    fi

    echo -e "${ICON_GEAR} Downloading ${model_hint}..."
    echo -e "${CYAN}Downloading to: $model_path${NC}"
    [ -n "${DOWNLOAD_PROXY:-}" ] && echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"

    # curl.exe via WSL interop (uses wslpath) — WSL only, not Git Bash
    local win_curl=""
    [ "$IS_WSL" = "true" ] && win_curl=$(command -v curl.exe 2>/dev/null)

    # Git Bash: use PowerShell Invoke-WebRequest which uses WinHTTP + Windows cert store,
    # bypassing SChannel TLS handshake failures with SSL-intercepting corporate proxies.
    # PowerShell 5.1 ServicePointManager does not support https:// proxy URIs — coerce to http://.
    if [ "$IS_GITBASH" = "true" ] && command -v powershell.exe >/dev/null 2>&1; then
        local win_out; win_out=$(cygpath -w "$model_path")
        local ps_cmd="\$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '${model_url}' -OutFile '${win_out}' -UseBasicParsing"
        if [ -n "${DOWNLOAD_PROXY:-}" ]; then
            local http_proxy; http_proxy=$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')
            ps_cmd+=" -Proxy '${http_proxy}'"
        fi
        powershell.exe -NoProfile -NonInteractive -Command "$ps_cmd" &
        _await_download $! "$model_path" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
    elif [ -n "${DOWNLOAD_PROXY:-}" ] && [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$model_path")
        local http_proxy_win; http_proxy_win=$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')
        "$win_curl" -L --proxy "$http_proxy_win" --ssl-no-revoke --no-progress-meter --show-error -o "$win_path" "$model_url" &
        _await_download $! "$model_path" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
    elif [ -n "${DOWNLOAD_PROXY:-}" ] && command -v curl >/dev/null 2>&1; then
        local http_proxy_curl; http_proxy_curl=$(echo "$DOWNLOAD_PROXY" | sed 's|^https://|http://|')
        curl -L --proxy "$http_proxy_curl" --progress-bar --show-error -o "$model_path" "$model_url" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    elif [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$model_path")
        "$win_curl" -L --no-progress-meter --show-error -o "$win_path" "$model_url" &
        _await_download $! "$model_path" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar --show-error -o "$model_path" "$model_url" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "${DOWNLOAD_PROXY:-}" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$DOWNLOAD_PROXY" -e "https_proxy=$DOWNLOAD_PROXY")
        wget --no-verbose --show-progress --progress=dot:giga "${wget_proxy_args[@]}" -O "$model_path" "$model_url" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    fi

    echo -e "${GREEN}✔ Model downloaded successfully${NC}"
    return 0
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
    
    echo -e "${YELLOW}⚠ Target model not found: $MODEL_FILE${NC}"
    echo -e "${CYAN}Scanning for available ${MODEL_FAMILY} GGUF models...${NC}"
    local found_model; found_model=$(find "$MODEL_STORAGE_DIR" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | grep -Ei "$MODEL_FILE_PATTERN" | head -1)
    if [ -n "$found_model" ]; then
        MODEL_FILE=$(basename "$found_model")
        echo -e "${GREEN}✔ Using available model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi
    
    if [ "$MODEL_STRICT_FAMILY" = "true" ]; then
        echo -e "${RED}✘ No ${MODEL_FAMILY} models found in $MODEL_STORAGE_DIR${NC}"; return 1
    fi
    return 1
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

    local crane_bin crane_tmp=""
    crane_bin=$(command -v crane 2>/dev/null)
    if [ -z "$crane_bin" ]; then
        local crane_url="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz"
        echo -e "${CYAN}  Downloading crane (registry pull tool) via proxy...${NC}"
        crane_tmp=$(mktemp -d)
        if ! curl --proxy "$proxy" -fsSL "$crane_url" | tar xz -C "$crane_tmp" crane; then
            echo -e "${RED}  ✘ Failed to download crane — check proxy and GitHub access${NC}"
            rm -rf "$crane_tmp"; return 1
        fi
        crane_bin="$crane_tmp/crane"
    fi
    echo -e "${CYAN}  Pulling $image from registry via proxy (WSL2, not daemon VM)...${NC}"
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
      sed -i 's|http://|https://|g' /etc/apt/sources.list && \
      printf 'Acquire::https::Proxy "%s";\nAcquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' "\${apt_proxy}" > /etc/apt/apt.conf.d/01proxy; \
    fi
RUN apt-get update && apt-get install -y \
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
    docker run -d --name "$WORKBENCH" --network "$wb_network" --privileged \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=$no_proxy_hosts" \
        -v "$(to_host_path "$(pwd)"):/$WORKSPACE_DIR" \
        --workdir "/$WORKSPACE_DIR" \
        "${extra_flags[@]}" \
        "$IMAGE_NAME" /bin/bash -c "$entrypoint"
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
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
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

    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$HUB_NETWORK" --gpus "$_gpus_flag" --restart on-failure:3 \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port 8080 \
        --parallel "$MODEL_MAX_SLOTS" -ngl 99 -c "$MODEL_CTX_SIZE" --flash-attn on \
        -ctk q8_0 -ctv q8_0 \
        --repeat-penalty 1.1 --repeat-last-n 128 \
        "${_ts_args[@]}" || {
        echo -e "${RED}✘ Failed to start engine container${NC}"; return 1
    }

    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        mkdir -p "$HOME/.ai-coder"
        local config_content; config_content=$(get_litellm_config)
        cat > "$HOME/.ai-coder/litellm_config.yaml" <<EOF
$config_content
EOF
        docker run -d --name "$GLOBAL_PROXY_NAME" --network "$HUB_NETWORK" -p 4000:4000 --restart always \
            -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
            -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
            -v "$(to_host_path "$HOME/.ai-coder/litellm_config.yaml"):/app/config.yaml:ro" \
            "$LITELLM_IMAGE" --config /app/config.yaml || {
            echo -e "${RED}✘ Failed to start proxy container${NC}"; return 1
        }
    fi

    # When isolation is active, bridge the engine (and proxy if running) onto
    # the isolated network so workbench containers can reach them.
    if [ "${NETWORK_INTERNAL:-false}" = "true" ]; then
        docker network connect "$HUB_ISOLATED_NET" "$GLOBAL_ENGINE_NAME" || \
            { echo -e "${RED}✘ Failed to connect engine to isolated network${NC}"; return 1; }
        if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
            docker network connect "$HUB_ISOLATED_NET" "$GLOBAL_PROXY_NAME" || \
                { echo -e "${RED}✘ Failed to connect proxy to isolated network${NC}"; return 1; }
        fi
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
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" \
        $(docker ps -q --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" \
        $(docker ps -aq --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
    docker network rm "$HUB_NETWORK" "$HUB_ISOLATED_NET" 2>/dev/null || true
}

handle_command() {
    cmd="${1:-}"
    case "$cmd" in
        --help|-h)
            cat <<HELP
Usage: $(basename "$0") [COMMAND]

Commands:
  spawn              Execute command in active workbench
  --status           Show GPU and engine status dashboard
  --setup            Create shell alias and configure proxy settings
  --clean            Stop and remove all containers
  --rebuild          Remove the workbench image to force a full rebuild
  --menu             Reset tool preference and show menu
  --gpu-mode         Reset GPU mode preference (single vs multi-GPU)
  --build-only       Build the workbench image then exit (no Hub or agent launch)
  --help             Show this message
HELP
            exit 0
            ;;
        --status)
            exec "$(dirname "$(realpath "$0")")/ai-status.sh"
            ;;
        --rebuild)
            if [ -n "${IMAGE_NAME:-}" ]; then
                echo -e "${CYAN}◈ Removing image [$IMAGE_NAME]...${NC}"
                docker rmi "$IMAGE_NAME" 2>/dev/null && echo -e "${GREEN}✔ Image removed. It will be rebuilt on next run.${NC}" || echo -e "${YELLOW}  Image not found — nothing to remove.${NC}"
            else
                echo -e "${RED}✘ IMAGE_NAME not set — source a child script first.${NC}"
            fi
            exit 0
            ;;
        --clean)
            teardown
            exit 0
            ;;
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
