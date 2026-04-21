#!/usr/bin/env bash
# ==============================================================================
# AI-CODER-OC.SH | OpenCode Variant | Alias: 'oc'
# Architecture: Hub & Spoke (Docker)
# - Hub: Shared 'ai-hub-engine' and 'ai-hub-proxy' containers.
# - Spoke: Project-specific 'coder-<project-id>' workbench container.
#
# Usage:
#   oc                        - Launch OpenCode in active workbench
#   oc --status               - Show GPU and engine status dashboard
#   oc --clean                - Stop and remove all containers
#   oc --setup-path           - Create shell alias for this script
# ==============================================================================
set -euo pipefail

# --- [ GLOBAL CONFIGURATION ] -------------------------------------------------
ALIAS_NAME="oc"
DOCKER_BIN="C:\Program Files\Docker\Docker\Docker Desktop.exe"
MODEL_STORAGE_DIR="$HOME/ai-models"
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
# 16GB tier: 26B MoE model (3.8B active params) fits in 16GB at IQ4_XS (13.4GB) - massive quality jump over E4B
GEMMA_16GB_FILE="${GEMMA_16GB_FILE:-gemma-4-26B-A4B-it-UD-IQ4_XS.gguf}"
GEMMA_16GB_URL="${GEMMA_16GB_URL:-https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-IQ4_XS.gguf}"
GEMMA_24GB_FILE="${GEMMA_24GB_FILE:-google_gemma-4-26B-A4B-it-Q5_K_M.gguf}"
GEMMA_24GB_URL="${GEMMA_24GB_URL:-https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF/resolve/main/google_gemma-4-26B-A4B-it-Q5_K_M.gguf}"
GEMMA_32GB_FILE="${GEMMA_32GB_FILE:-gemma-4-31B-it-Q5_K_M.gguf}"
GEMMA_32GB_URL="${GEMMA_32GB_URL:-https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/gemma-4-31B-it-Q5_K_M.gguf}"

# Download proxy (leave empty for direct connections, e.g. export DOWNLOAD_PROXY="http://core-wsa1:80")
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

# VRAM tier cutoffs (override if needed)
TIER_8GB_MIN="${TIER_8GB_MIN:-8}"
TIER_12GB_MIN="${TIER_12GB_MIN:-12}"
TIER_16GB_MIN="${TIER_16GB_MIN:-15}"
TIER_24GB_MIN="${TIER_24GB_MIN:-24}"
TIER_32GB_MIN="${TIER_32GB_MIN:-31}"

# Multi-Agent Allocation
MAX_SLOTS=1
CTX_PER_SLOT=65536
IMAGE_NAME="opencode-engineer-v1"

# --- [ ENVIRONMENT & SHELL ] --------------------------------------------------
export MSYS_NO_PATHCONV=1
PROJECT_ID=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
LOCAL_STACK_DIR="$(pwd)/.oc-stack"
mkdir -p "$MODEL_STORAGE_DIR" "$LOCAL_STACK_DIR"

# Visuals & Colors
readonly NC='\033[0m'; readonly BOLD='\033[1m'; readonly GREEN='\033[0;32m'; readonly RED='\033[0;31m'; readonly CYAN='\033[0;36m'; readonly YELLOW='\033[1;33m'
readonly ICON_OK=" ${GREEN}[OK]${NC} "; readonly ICON_GEAR=" ${CYAN}[**]${NC} "; readonly ICON_WAIT=" ${CYAN}[..]${NC} "

IS_WSL=$(grep -qi Microsoft /proc/version 2>/dev/null && echo "true" || echo "false")
IS_GITBASH=$(expr "$(uname -s)" : '.*MINGW.*' >/dev/null 2>&1 && echo "true" || echo "false")
if [ "$IS_GITBASH" = "true" ]; then
    SMI="nvidia-smi.exe"
else
    SMI="nvidia-smi"
fi

# Normalize path for host filesystem (handles WSL2 paths)
to_host_path() {
    local abs_path; abs_path=$(realpath "$1")
    if [ "$IS_WSL" == "true" ]; then
        echo "$abs_path"
    else
        echo "$abs_path" | sed 's/^\/\([a-z]\)\//\/\/\1\//'
    fi
}

run_cmd() { "$@"; }

# --- [ CORE LOGIC ] -----------------------------------------------------------

check_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo -e "${ICON_GEAR} Starting Docker Desktop..."
        if [ "$IS_WSL" == "true" ]; then
            powershell.exe -Command "Start-Process '$DOCKER_BIN'" >/dev/null 2>&1 || {
                echo -e "${RED}[X] Failed to start Docker${NC}"; return 1
            }
        else
            start "" "$DOCKER_BIN" || { echo -e "${RED}[X] Failed to start Docker${NC}"; return 1; }
        fi

        local wait_count=0
        echo -ne "${CYAN}[..] Waiting for Daemon...${NC} "
        until docker info >/dev/null 2>&1; do
            wait_count=$((wait_count + 1))
            if [ "$wait_count" -gt 60 ]; then
                echo -e " ${RED}TIMEOUT${NC}"; return 1
            fi
            echo -ne "."; sleep 5
        done
        echo -e " ${GREEN}ONLINE${NC}"
    fi
}

download_model() {
    if [ -n "${MODEL_FILE:-}" ] && [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        return 0
    fi

    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}[X] Neither wget nor curl found. Cannot download model.${NC}"
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
        *) echo -e "${RED}[X] Unsupported target model: $MODEL_FILE${NC}"; return 1 ;;
    esac

    model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"

    if [ -z "$model_url" ]; then
        echo -e "${RED}[X] Missing download URL for $MODEL_FILE${NC}"
        return 1
    fi

    echo -e "${ICON_GEAR} Downloading ${model_hint}..."
    echo -e "${CYAN}Downloading to: $model_path${NC}"
    [ -n "${DOWNLOAD_PROXY:-}" ] && echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"

    # curl.exe (Windows System32) uses WinInet - handles corporate SSL inspection proxy
    # correctly with --ssl-no-revoke, and bypasses WSL2 network isolation.
    local win_curl
    win_curl=$(command -v curl.exe 2>/dev/null)

    if [ -n "${DOWNLOAD_PROXY:-}" ] && [ -n "$win_curl" ]; then
        local win_path; win_path=$(wslpath -w "$model_path")
        "$win_curl" -L --proxy "$DOWNLOAD_PROXY" --ssl-no-revoke --no-progress-meter --show-error -o "$win_path" "$model_url" &
        local dl_pid=$!
        while kill -0 "$dl_pid" 2>/dev/null; do
            local sz; sz=$(stat -c%s "$model_path" 2>/dev/null || echo 0)
            printf "\r  Downloaded: %-12s" "$(numfmt --to=iec-i --suffix=B "$sz")"
            sleep 2
        done
        printf "\n"
        wait "$dl_pid" || { echo -e "${RED}[X] Download failed${NC}"; return 1; }
    elif [ -n "${DOWNLOAD_PROXY:-}" ] && command -v curl >/dev/null 2>&1; then
        curl -L --proxy "$DOWNLOAD_PROXY" --progress-bar --show-error -o "$model_path" "$model_url" || {
            echo -e "${RED}[X] Download failed${NC}"; return 1
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
        wait "$dl_pid" || { echo -e "${RED}[X] Download failed${NC}"; return 1; }
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar --show-error -o "$model_path" "$model_url" || {
            echo -e "${RED}[X] Download failed${NC}"; return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        local wget_proxy_args=()
        [ -n "${DOWNLOAD_PROXY:-}" ] && wget_proxy_args=(-e "use_proxy=yes" -e "http_proxy=$DOWNLOAD_PROXY" -e "https_proxy=$DOWNLOAD_PROXY")
        wget --no-verbose --show-progress --progress=dot:giga "${wget_proxy_args[@]}" -O "$model_path" "$model_url" || {
            echo -e "${RED}[X] Download failed${NC}"; return 1
        }
    fi

    echo -e "${GREEN}[OK] Model downloaded successfully${NC}"
    return 0
}

detect_model() {
    local vram_list; vram_list=$($SMI --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null) || {
        echo -e "${RED}[X] nvidia-smi failed${NC}"; return 1
    }

    local total_vram=0
    for v in $vram_list; do
        case "$v" in *[!0-9]*) continue ;; *) total_vram=$((total_vram + v)) ;; esac
    done
    VRAM_GB=$((total_vram / 1024))

    echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC}"

    if   [ "$VRAM_GB" -ge "$TIER_32GB_MIN" ]; then MODEL_FILE="$GEMMA_32GB_FILE"; MODEL_TIER="32GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_24GB_MIN" ]; then MODEL_FILE="$GEMMA_24GB_FILE"; MODEL_TIER="24GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_16GB_MIN" ]; then MODEL_FILE="$GEMMA_16GB_FILE"; MODEL_TIER="16GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_12GB_MIN" ]; then MODEL_FILE="$GEMMA_12GB_FILE"; MODEL_TIER="12GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_8GB_MIN"  ]; then MODEL_FILE="$GEMMA_8GB_FILE";  MODEL_TIER="8GB-tier"
    else MODEL_FILE="$GEMMA_8GB_FILE"; MODEL_TIER="<${TIER_8GB_MIN}GB (fallback to 8GB tier model)"
    fi

    echo -e "${ICON_GEAR} Model Tier: ${BOLD}${MODEL_TIER}${NC}"
    echo -e "${ICON_GEAR} Tier Cutoffs: 8GB>=${TIER_8GB_MIN}, 12GB>=${TIER_12GB_MIN}, 16GB>=${TIER_16GB_MIN}, 24GB>=${TIER_24GB_MIN}, 32GB>=${TIER_32GB_MIN}"
    echo -e "${ICON_GEAR} Tier Model: ${CYAN}${MODEL_FILE}${NC}"

    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${ICON_OK}Target Model: ${CYAN}${MODEL_FILE}${NC}"; return 0
    fi

    echo -e "${YELLOW}[!] Target model not found: $MODEL_FILE${NC}"
    echo -e "${CYAN}Scanning for available Gemma GGUF models...${NC}"

    local found_model
    found_model=$(find "$MODEL_STORAGE_DIR" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | grep -Ei 'gemma' | head -1)

    if [ -n "$found_model" ]; then
        MODEL_FILE=$(basename "$found_model")
        echo -e "${GREEN}[OK] Using available model: ${CYAN}${MODEL_FILE}${NC}"; return 0
    fi

    echo -e "${RED}[X] No Gemma models found in $MODEL_STORAGE_DIR${NC}"
    return 1
}

BASE_IMAGE="node:20-bullseye-slim"

pull_base_image_via_proxy() {
    local image="$1" proxy="$2"
    local crane_bin crane_tmp=""
    crane_bin=$(command -v crane 2>/dev/null)
    if [ -z "$crane_bin" ]; then
        local crane_url="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz"
        echo -e "${CYAN}  Downloading crane (registry pull tool) via proxy...${NC}"
        crane_tmp=$(mktemp -d)
        if ! curl --proxy "$proxy" -fsSL "$crane_url" | tar xz -C "$crane_tmp" crane; then
            echo -e "${RED}  [X] Failed to download crane - check proxy and GitHub access${NC}"
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
        echo -e "${RED}  [X] crane pull failed${NC}"
        rm -f "$image_tar"; [ -n "$crane_tmp" ] && rm -rf "$crane_tmp"
        return 1
    fi
}

build_image() {
    image_check=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
    if [ -n "$image_check" ]; then return 0; fi

    echo -e "${ICON_GEAR} Building OpenCode Image..."

    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        if [ -n "${DOWNLOAD_PROXY:-}" ]; then
            pull_base_image_via_proxy "$BASE_IMAGE" "$DOWNLOAD_PROXY" || return 1
        else
            docker pull "$BASE_IMAGE" || { echo -e "${RED}[X] Base image pull failed${NC}"; return 1; }
        fi
    fi

    local proxy_args=()
    local npm_proxy_cmds=""
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        # Resolve proxy hostname -> IP so Docker daemon's build VM (separate DNS) can reach it
        local build_proxy="$DOWNLOAD_PROXY"
        local _proxy_host; _proxy_host=$(echo "$DOWNLOAD_PROXY" | sed 's|.*://||;s|:.*||')
        local _proxy_ip; _proxy_ip=$(getent hosts "$_proxy_host" 2>/dev/null | awk '{print $1}' | head -1)
        [ -n "$_proxy_ip" ] && build_proxy=$(echo "$DOWNLOAD_PROXY" | sed "s/$_proxy_host/$_proxy_ip/")
        proxy_args=(--build-arg "PROXY_URL=$build_proxy")
        npm_proxy_cmds="RUN npm config set proxy $build_proxy && npm config set https-proxy $build_proxy && npm config set strict-ssl false"
    fi

    cat > "$LOCAL_STACK_DIR/Dockerfile.oc" <<DOCKERFILE
FROM node:20-bullseye-slim
ARG PROXY_URL
ENV http_proxy=\${PROXY_URL} https_proxy=\${PROXY_URL} HTTP_PROXY=\${PROXY_URL} HTTPS_PROXY=\${PROXY_URL} \
    no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    tree ripgrep curl git \
    --no-install-recommends && rm -rf /var/lib/apt/lists/*
${npm_proxy_cmds}
RUN npm install -g opencode-ai
RUN opencode --version
WORKDIR /workspace
DOCKERFILE

    docker build -t "$IMAGE_NAME" "${proxy_args[@]}" -f "$LOCAL_STACK_DIR/Dockerfile.oc" "$LOCAL_STACK_DIR" || {
        echo -e "${RED}[X] Docker build failed${NC}"; return 1
    }
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub..."

    # Remove any pre-existing engine/proxy containers (could be crashed/competing with download)
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true

    for img in "$LLAMA_IMAGE" "$LITELLM_IMAGE"; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            echo -e "${CYAN}  Pulling $img ...${NC}"
            docker pull "$img" || { echo -e "${RED}[X] Failed to pull $img${NC}"; return 1; }
        fi
    done

    cat > "$LOCAL_STACK_DIR/litellm_config.yaml" <<EOF
model_list:
  - model_name: gemma-local
    litellm_params:
      model: openai/local
      api_base: http://$GLOBAL_ENGINE_NAME:8080/v1
      api_key: sk-1234
      timeout: 600
      stream_timeout: 600

litellm_settings:
  request_timeout: 600
  drop_params: true
  num_retries: 0
EOF

    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$HUB_NETWORK" --gpus all --restart on-failure:3 \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port 8080 \
        --parallel "$MAX_SLOTS" -ngl 99 -c "$CTX_PER_SLOT" --flash-attn on
    if [ $? -ne 0 ]; then echo -e "${RED}[X] Failed to start engine container${NC}"; return 1; fi

    docker run -d --name "$GLOBAL_PROXY_NAME" --network "$HUB_NETWORK" -p 4000:4000 --restart always \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$LOCAL_STACK_DIR/litellm_config.yaml"):/app/config.yaml:ro" \
        "$LITELLM_IMAGE" --config /app/config.yaml
    if [ $? -ne 0 ]; then echo -e "${RED}[X] Failed to start proxy container${NC}"; return 1; fi
}

write_opencode_config() {
    local config_dir="$LOCAL_STACK_DIR/opencode-config"
    mkdir -p "$config_dir"
    cat > "$config_dir/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "permission": {
    "write": "deny"
  },
  "model": "local/gemma-local",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Gemma (llama.cpp)",
      "options": {
        "baseURL": "http://$GLOBAL_PROXY_NAME:4000/v1",
        "apiKey": "sk-local-bypass"
      },
      "models": {
        "gemma-local": {
          "name": "Gemma 4 Local",
          "contextLength": 65536
        }
      }
    }
  }
}
EOF
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    write_opencode_config
    docker run -d --name "$WORKBENCH" --network "$HUB_NETWORK" --privileged \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_PROXY_NAME,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$(pwd)"):/workspace" \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$LOCAL_STACK_DIR/opencode-config"):/root/.config/opencode" \
        "$IMAGE_NAME" /bin/bash -c "trap 'true' EXIT; while true; do sleep 3600; done"
}

ensure_workbench_running() {
    if [ -n "$(docker ps -q -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then return 0; fi
    if [ -n "$(docker ps -aq -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        docker start "$WORKBENCH" >/dev/null 2>&1 || return 1; return 0
    fi
    start_workbench
}

# --- [ COMMANDS ] -------------------------------------------------------------

handle_command() {
    cmd="${1:-}"
    case "$cmd" in
        --help|-h)
            cat <<HELP
Usage: $(basename "$0") [COMMAND]

Commands:
  --status           Show GPU and engine status dashboard
  --setup-path       Create shell alias for this script
  --clean            Stop and remove all containers
  --help             Show this message
HELP
            exit 0 ;;
        --status)
            exec "$(dirname "$(realpath "$0")")/ai-status.sh" ;;
        --clean)
            echo -e "${CYAN}Tearing down Hub & Project Spokes...${NC}"
            docker stop $GLOBAL_ENGINE_NAME $GLOBAL_PROXY_NAME $(docker ps -q --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
            docker rm   $GLOBAL_ENGINE_NAME $GLOBAL_PROXY_NAME $(docker ps -aq --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
            exit 0 ;;
        --setup-path)
            rc_file="$HOME/.bashrc"
            [ "$SHELL" != "${SHELL%zsh}" ] && rc_file="$HOME/.zshrc"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo "alias $ALIAS_NAME='$(realpath "$0")'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' set. Run: source $rc_file"
            exit 0 ;;
        "") ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"; echo "Run: $0 --help"; exit 1 ;;
    esac
}

[ "$#" -gt 0 ] && handle_command "$@"

# --- [ IGNITION ] -------------------------------------------------------------

check_docker || { echo -e "${RED}[X] Docker initialization failed${NC}"; exit 1; }
detect_model || true
download_model || { echo -e "${RED}[X] Model download failed${NC}"; exit 1; }
detect_model || { echo -e "${RED}[X] Model detection failed${NC}"; exit 1; }
build_image || { echo -e "${RED}[X] Image build failed${NC}"; exit 1; }

WORKBENCH="${WORKBENCH_PREFIX}-${PROJECT_ID}"
docker network create "$HUB_NETWORK" 2>/dev/null || true

if [ -z "$(docker ps -q -f name=^/${GLOBAL_ENGINE_NAME}$ 2>/dev/null)" ]; then
    docker rm "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
    start_hub_engine || { echo -e "${RED}[X] Hub startup failed${NC}"; exit 1; }
fi

ensure_workbench_running || { echo -e "${RED}[X] Workbench startup failed${NC}"; exit 1; }

echo -ne "${CYAN}[..] Syncing VRAM Slots:${NC} "
retry_count=0
max_retries=90
engine_ready=false
proxy_ready=false

while [ "$retry_count" -lt "$max_retries" ]; do
    if docker exec "$GLOBAL_ENGINE_NAME" curl -s -m 2 http://localhost:8080/v1/models 2>/dev/null | grep -q '"id"'; then
        engine_ready=true
    fi
    if curl -s -m 2 http://localhost:4000/v1/models 2>/dev/null | grep -q '"gemma-local"'; then
        proxy_ready=true
    fi
    if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then break; fi
    retry_count=$((retry_count + 1))
    echo -ne "."
    sleep 2
done

if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then
    echo -e " ${GREEN}READY${NC}"
else
    echo -e " ${RED}TIMEOUT${NC}"
    echo -e "${RED}[X] Engine/Proxy failed to initialize after $((retry_count * 2)) seconds${NC}"
    echo -e "${CYAN}Diagnostics:${NC}"

    if [ -n "$(docker ps -aq -f name="$GLOBAL_ENGINE_NAME")" ]; then
        if [ -n "$(docker ps -q -f name="$GLOBAL_ENGINE_NAME")" ]; then
            echo "  Engine container is running. Last 30 logs:"
        else
            echo "  Engine container crashed/restarting. Last 30 logs:"
        fi
        docker logs "$GLOBAL_ENGINE_NAME" 2>&1 | tail -30 | sed 's/^/    /'
    else
        echo "  ${RED}[X] Engine container not found${NC}"
    fi

    echo -e "${CYAN}  Model location: $MODEL_STORAGE_DIR/$MODEL_FILE${NC}"
    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${GREEN}  [OK] Model file exists${NC}"
    else
        echo -e "${RED}  [X] Model file missing${NC}"
    fi

    if [ "$proxy_ready" != "true" ]; then
        echo "  Proxy container logs (last 30):"
        docker logs "$GLOBAL_PROXY_NAME" 2>&1 | tail -30 | sed 's/^/    /'
    fi
    exit 1
fi

echo -e "${ICON_GEAR} Attaching to workbench..."
if [ "$IS_GITBASH" = "true" ]; then
    winpty docker exec -it "$WORKBENCH" opencode
else
    docker exec -it "$WORKBENCH" opencode
fi