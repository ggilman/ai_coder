#!/bin/bash
# ==============================================================================
# AI-CODER-CORE.SH | Shared Infrastructure Library
# ==============================================================================
set -euo pipefail

# --- [ GLOBAL CONFIGURATION ] -------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PACKAGES_DIR="$(dirname "$SCRIPT_DIR")/packages"
DOCKER_BIN="C:\Program Files\Docker\Docker\Docker Desktop.exe"
GLOBAL_ENGINE_NAME="ai-hub-engine"
GLOBAL_PROXY_NAME="ai-hub-proxy"
HUB_NETWORK="ai-engineering-net"
WORKBENCH_PREFIX="coder"
LITELLM_IMAGE="ghcr.io/berriai/litellm:main-latest"
LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
STRICT_GEMMA_ONLY="true"

# Verified Gemma 4 GGUF direct downloads
GEMMA_8GB_FILE="${GEMMA_8GB_FILE:-gemma-4-E2B-it-Q4_K_M.gguf}"
GEMMA_8GB_URL="${GEMMA_8GB_URL:-https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf}"
GEMMA_12GB_FILE="${GEMMA_12GB_FILE:-gemma-4-E4B-it-Q8_0.gguf}"
GEMMA_12GB_URL="${GEMMA_12GB_URL:-https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q8_0.gguf}"
GEMMA_16GB_FILE="${GEMMA_16GB_FILE:-gemma-4-26B-A4B-it-UD-IQ4_XS.gguf}"
GEMMA_16GB_URL="${GEMMA_16GB_URL:-https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-IQ4_XS.gguf}"
GEMMA_24GB_FILE="${GEMMA_24GB_FILE:-google_gemma-4-26B-A4B-it-Q5_K_M.gguf}"
GEMMA_24GB_URL="${GEMMA_24GB_URL:-https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF/resolve/main/google_gemma-4-26B-A4B-it-Q5_K_M.gguf}"
GEMMA_32GB_FILE="${GEMMA_32GB_FILE:-gemma-4-31B-it-Q5_K_M.gguf}"
GEMMA_32GB_URL="${GEMMA_32GB_URL:-https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/gemma-4-31B-it-Q5_K_M.gguf}"

DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

# VRAM tier cutoffs
TIER_8GB_MIN="${TIER_8GB_MIN:-8}"
TIER_12GB_MIN="${TIER_12GB_MIN:-11}"
TIER_16GB_MIN="${TIER_16GB_MIN:-15}"
TIER_24GB_MIN="${TIER_24GB_MIN:-23}"
TIER_32GB_MIN="${TIER_32GB_MIN:-31}"

MAX_SLOTS=1             
CTX_PER_SLOT=65536      
BASE_IMAGE="node:20-bullseye-slim"

# --- [ ENVIRONMENT & SHELL ] --------------------------------------------------
export MSYS_NO_PATHCONV=1
PROJECT_ID=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Visuals & Colors
readonly NC='\033[0m'; readonly BOLD='\033[1m'; readonly GREEN='\033[0;32m'; readonly RED='\033[0;31m'; readonly CYAN='\033[0;36m'; readonly YELLOW='\033[1;33m'
readonly ICON_OK=" ${GREEN}✔${NC} "; readonly ICON_GEAR=" ${CYAN}⚙${NC} "; readonly ICON_WAIT=" ${CYAN}◈${NC} "

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
            powershell.exe -Command "Start-Process '$DOCKER_BIN'" >/dev/null 2>&1 || {
                echo -e "${RED}✘ Failed to start Docker${NC}"; return 1
            }
        else
            start "" "$DOCKER_BIN" || { echo -e "${RED}✘ Failed to start Docker${NC}"; return 1; }
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
        if [ "${VRAM_GB:-0}" -ge "$TIER_32GB_MIN" ]; then
            MODEL_FILE="$GEMMA_32GB_FILE"
        elif [ "${VRAM_GB:-0}" -ge "$TIER_24GB_MIN" ]; then
            MODEL_FILE="$GEMMA_24GB_FILE"
        elif [ "${VRAM_GB:-0}" -ge "$TIER_16GB_MIN" ]; then
            MODEL_FILE="$GEMMA_16GB_FILE"
        elif [ "${VRAM_GB:-0}" -ge "$TIER_12GB_MIN" ]; then
            MODEL_FILE="$GEMMA_12GB_FILE"
        elif [ "${VRAM_GB:-0}" -ge "$TIER_8GB_MIN" ]; then
            MODEL_FILE="$GEMMA_8GB_FILE"
        else
            MODEL_FILE="$GEMMA_8GB_FILE"
        fi
    fi

    case "$MODEL_FILE" in
        "$GEMMA_32GB_FILE") model_url="$GEMMA_32GB_URL"; model_hint="Gemma-4 31B Q5_K_M (32GB tier)" ;;
        "$GEMMA_24GB_FILE") model_url="$GEMMA_24GB_URL"; model_hint="Gemma-4 26B A4B Q5_K_M (24GB tier)" ;;
        "$GEMMA_16GB_FILE") model_url="$GEMMA_16GB_URL"; model_hint="Gemma-4 26B A4B UD-IQ4_XS (16GB tier)" ;;
        "$GEMMA_12GB_FILE") model_url="$GEMMA_12GB_URL"; model_hint="Gemma-4 E4B Q8_0 (12GB tier)" ;;
        "$GEMMA_8GB_FILE")  model_url="$GEMMA_8GB_URL";  model_hint="Gemma-4 E2B Q4_K_M (8GB tier)" ;;
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
        local dl_pid=$!
        while kill -0 "$dl_pid" 2>/dev/null; do
            local sz; sz=$(stat -c%s "$model_path" 2>/dev/null || echo 0)
            printf "\r  Downloaded: %-12s" "$(numfmt --to=iec-i --suffix=B "$sz")"
            sleep 2
        done
        printf "\n"
        wait "$dl_pid" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
    elif [ -n "${DOWNLOAD_PROXY:-}" ] && [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$model_path")
        "$win_curl" -L --proxy "$DOWNLOAD_PROXY" --ssl-no-revoke --no-progress-meter --show-error -o "$win_path" "$model_url" &
        local dl_pid=$!
        while kill -0 "$dl_pid" 2>/dev/null; do
            local sz; sz=$(stat -c%s "$model_path" 2>/dev/null || echo 0)
            printf "\r  Downloaded: %-12s" "$(numfmt --to=iec-i --suffix=B "$sz")"
            sleep 2
        done
        printf "\n"
        wait "$dl_pid" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
    elif [ -n "${DOWNLOAD_PROXY:-}" ] && command -v curl >/dev/null 2>&1; then
        curl -L --proxy "$DOWNLOAD_PROXY" --progress-bar --show-error -o "$model_path" "$model_url" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    elif [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$model_path")
        "$win_curl" -L --no-progress-meter --show-error -o "$win_path" "$model_url" &
        local dl_pid=$!
        while kill -0 "$dl_pid" 2>/dev/null; do
            local sz; sz=$(stat -c%s "$model_path" 2>/dev/null || echo 0)
            printf "\r  Downloaded: %-12s" "$(numfmt --to=iec-i --suffix=B "$sz")"
            sleep 2
        done
        printf "\n"
        wait "$dl_pid" || { echo -e "${RED}✘ Download failed${NC}"; return 1; }
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
    
    local total_vram=0
    for v in $vram_list; do 
        case "$v" in *[!0-9]*) continue ;; *) total_vram=$((total_vram + v)) ;; esac
    done
    VRAM_GB=$((total_vram / 1024))
    
    echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC}"
    
    if [ "$VRAM_GB" -ge "$TIER_32GB_MIN" ]; then
        MODEL_FILE="$GEMMA_32GB_FILE"
        MODEL_TIER="32GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_24GB_MIN" ]; then
        MODEL_FILE="$GEMMA_24GB_FILE"
        MODEL_TIER="24GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_16GB_MIN" ]; then
        MODEL_FILE="$GEMMA_16GB_FILE"
        MODEL_TIER="16GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_12GB_MIN" ]; then
        MODEL_FILE="$GEMMA_12GB_FILE"
        MODEL_TIER="12GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_8GB_MIN" ]; then
        MODEL_FILE="$GEMMA_8GB_FILE"
        MODEL_TIER="8GB-tier"
    else
        MODEL_FILE="$GEMMA_8GB_FILE"
        MODEL_TIER="<${TIER_8GB_MIN}GB (fallback to 8GB tier model)"
    fi
    echo -e "${ICON_GEAR} Model Tier: ${BOLD}${MODEL_TIER}${NC}"
    echo -e "${ICON_GEAR} Tier Model: ${CYAN}${MODEL_FILE}${NC}"
    
    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${ICON_OK} Target Model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⚠ Target model not found: $MODEL_FILE${NC}"
    echo -e "${CYAN}Scanning for available Gemma GGUF models...${NC}"
    local found_model; found_model=$(find "$MODEL_STORAGE_DIR" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | grep -Ei 'gemma' | head -1)
    if [ -n "$found_model" ]; then
        MODEL_FILE=$(basename "$found_model")
        echo -e "${GREEN}✔ Using available model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi
    
    if [ "$STRICT_GEMMA_ONLY" = "true" ]; then
        echo -e "${RED}✘ No Gemma models found in $MODEL_STORAGE_DIR${NC}"; return 1
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
        docker load < "$image_tar"
        local rc=$?
        rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
        return $rc
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
    --no-install-recommends && rm -rf /var/lib/apt/lists/*
ENV http_proxy=\${PROXY_URL} https_proxy=\${PROXY_URL} HTTP_PROXY=\${PROXY_URL} HTTPS_PROXY=\${PROXY_URL} \
    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1
${pm_proxy_cmds}
${install_cmds}
WORKDIR /workspace
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
    local cmd_exec="docker exec -it $*"
    if [ "$IS_GITBASH" = "true" ]; then
        winpty $cmd_exec
    else
        eval $cmd_exec
    fi
}

run_workbench() {
    # Usage: run_workbench [extra docker run flags...] [-- <entrypoint-cmd>]
    # Starts the workbench with standard flags. Pass a custom entrypoint after --.
    local extra_flags=()
    local entrypoint='trap '"'"'true'"'"' EXIT; while true; do sleep 3600; done'
    local past_sep=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then past_sep=true; continue; fi
        if $past_sep; then entrypoint="$arg"; else extra_flags+=("$arg"); fi
    done
    docker run -d --name "$WORKBENCH" --network "$HUB_NETWORK" --privileged \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_PROXY_NAME,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$(pwd)"):/workspace" \
        "${extra_flags[@]}" \
        "$IMAGE_NAME" /bin/bash -c "$entrypoint"
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub..."
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    
    # Use a hook for the config content
    local config_content; config_content=$(get_litellm_config)
    cat > "$LOCAL_STACK_DIR/litellm_config.yaml" <<EOF
$config_content
EOF

    for img in "$LLAMA_IMAGE" "$LITELLM_IMAGE"; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            echo -e "${CYAN}  Pulling $img ...${NC}"
            docker pull "$img" || { echo -e "${RED}✘ Failed to pull $img${NC}"; return 1; }
        fi
    done

    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$HUB_NETWORK" --gpus all --restart on-failure:3 \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port 8080 \
        --parallel "$MAX_SLOTS" -ngl 99 -c "$CTX_PER_SLOT" --flash-attn on \
        -ctk q8_0 -ctv q8_0
    if [ $? -ne 0 ]; then echo -e "${RED}✘ Failed to start engine container${NC}"; return 1; fi

    docker run -d --name "$GLOBAL_PROXY_NAME" --network "$HUB_NETWORK" -p 4000:4000 --restart always \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$LOCAL_STACK_DIR/litellm_config.yaml"):/app/config.yaml:ro" \
        "$LITELLM_IMAGE" --config /app/config.yaml
    if [ $? -ne 0 ]; then echo -e "${RED}✘ Failed to start proxy container${NC}"; return 1; fi
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
    docker stop $GLOBAL_ENGINE_NAME $GLOBAL_PROXY_NAME $(docker ps -q --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
    docker rm   $GLOBAL_ENGINE_NAME $GLOBAL_PROXY_NAME $(docker ps -aq --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
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
  --setup-path       Create shell alias for this script
  --clean            Stop and remove all containers
  --rebuild          Remove the workbench image to force a full rebuild
  --menu             Reset tool preference and show menu
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
        --setup-path)
            # ALIAS_NAME is set by launcher
            rc_file="$HOME/.bashrc"
            if [ "$IS_GITBASH" = "true" ]; then
                rc_file="$HOME/.bash_profile"
            elif [ "$SHELL" != "${SHELL%zsh}" ]; then
                rc_file="$HOME/.zshrc"
            fi
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo "alias $ALIAS_NAME='$(realpath "$0")'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' added to $rc_file. Run: source $rc_file"
            exit 0
            ;;
        "")
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo "Run: $0 --help"
            exit 1
            ;;
    esac
}
