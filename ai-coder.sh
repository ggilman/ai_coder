#!/bin/bash
# ==============================================================================
# AI-CODER.SH v4.8 | Dual-GPU Pool (32GB) | Alias: 'claude'
# Final "Zero-Space" Path Resolution for WSL2 & Docker Desktop
# ==============================================================================

set -euo pipefail

# --- [ GLOBAL CONFIGURATION ] -------------------------------------------------
ALIAS_NAME="claude"
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
GEMMA_24GB_FILE="${GEMMA_24GB_FILE:-google_gemma-4-26B-A4B-it-Q5_K_M.gguf}"
GEMMA_24GB_URL="${GEMMA_24GB_URL:-https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF/resolve/main/google_gemma-4-26B-A4B-it-Q5_K_M.gguf}"
GEMMA_32GB_FILE="${GEMMA_32GB_FILE:-gemma-4-31B-it-Q5_K_M.gguf}"
GEMMA_32GB_URL="${GEMMA_32GB_URL:-https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/gemma-4-31B-it-Q5_K_M.gguf}"

# VRAM tier cutoffs (override if needed)
TIER_8GB_MIN="${TIER_8GB_MIN:-8}"
TIER_12GB_MIN="${TIER_12GB_MIN:-12}"
TIER_24GB_MIN="${TIER_24GB_MIN:-24}"
TIER_32GB_MIN="${TIER_32GB_MIN:-31}"

# Multi-Agent Allocation (Optimized for 32GB)
MAX_SLOTS=4             
CTX_PER_SLOT=32768      
IMAGE_NAME="claude-engineer-v4-8"

# --- [ ENVIRONMENT & SHELL ] --------------------------------------------------
export MSYS_NO_PATHCONV=1
PROJECT_ID=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
LOCAL_STACK_DIR="$(pwd)/.claude-stack"
mkdir -p "$MODEL_STORAGE_DIR" "$LOCAL_STACK_DIR"

# Visuals & Colors
readonly NC='\033[0m'; readonly BOLD='\033[1m'; readonly GREEN='\033[0;32m'; readonly RED='\033[0;31m'; readonly CYAN='\033[0;36m'; readonly YELLOW='\033[1;33m'
readonly ICON_OK=" ${GREEN}✔${NC} "; readonly ICON_GEAR=" ${CYAN}⚙${NC} "; readonly ICON_WAIT=" ${CYAN}◈${NC} "

IS_WSL=$(grep -qi Microsoft /proc/version 2>/dev/null && echo "true" || echo "false")
IS_GITBASH=$(expr "$(uname -s)" : '.*MINGW.*' >/dev/null 2>&1 && echo "true" || echo "false")
if [ "$IS_GITBASH" = "true" ]; then
    SMI="nvidia-smi.exe"
else
    SMI="nvidia-smi"
fi

# Normalize path for host filesystem
to_host_path() {
    local abs_path; abs_path=$(realpath "$1")
    if [ "$IS_WSL" == "true" ]; then
        echo "$abs_path"
    else
        echo "$abs_path" | sed 's/^\/\([a-z]\)\//\/\/\1\//'
    fi
}

# Execute command with optional display
run_cmd() { "$@"; }

# --- [ CORE LOGIC ] -----------------------------------------------------------

check_docker() {
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
}

download_model() {
    # If the target model is already present, skip download.
    if [ -n "${MODEL_FILE:-}" ] && [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        return 0
    fi

    # Check for wget or curl
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
        elif [ "${VRAM_GB:-0}" -ge "$TIER_12GB_MIN" ]; then
            MODEL_FILE="$GEMMA_12GB_FILE"
        elif [ "${VRAM_GB:-0}" -ge "$TIER_8GB_MIN" ]; then
            MODEL_FILE="$GEMMA_8GB_FILE"
        else
            MODEL_FILE="$GEMMA_8GB_FILE"
        fi
    fi

    case "$MODEL_FILE" in
        "$GEMMA_32GB_FILE")
            model_url="$GEMMA_32GB_URL"
            model_hint="Gemma-4 31B Q5_K_M (32GB tier)"
            ;;
        "$GEMMA_24GB_FILE")
            model_url="$GEMMA_24GB_URL"
            model_hint="Gemma-4 26B A4B Q5_K_M (24GB tier)"
            ;;
        "$GEMMA_12GB_FILE")
            model_url="$GEMMA_12GB_URL"
            model_hint="Gemma-4 E4B Q8_0 (12GB tier)"
            ;;
        "$GEMMA_8GB_FILE")
            model_url="$GEMMA_8GB_URL"
            model_hint="Gemma-4 E2B Q4_K_M (8GB tier)"
            ;;
        *)
            echo -e "${RED}✘ Unsupported target model: $MODEL_FILE${NC}"
            return 1
            ;;
    esac

    model_path="$MODEL_STORAGE_DIR/$MODEL_FILE"

    if [ -z "$model_url" ]; then
        echo -e "${RED}✘ Missing download URL for $MODEL_FILE${NC}"
        echo -e "${CYAN}Set one of these environment variables before running:${NC}"
        echo "  export GEMMA_32GB_URL='https://.../gemma-4-31B-it-Q5_K_M.gguf'"
        echo "  export GEMMA_24GB_URL='https://.../google_gemma-4-26B-A4B-it-Q5_K_M.gguf'"
        echo "  export GEMMA_12GB_URL='https://.../gemma-4-E4B-it-Q8_0.gguf'"
        echo "  export GEMMA_8GB_URL='https://.../gemma-4-E2B-it-Q4_K_M.gguf'"
        return 1
    fi

    echo -e "${ICON_GEAR} Downloading ${model_hint}..."
    echo -e "${CYAN}Downloading to: $model_path${NC}"

    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress --progress=bar:force:noscroll -O "$model_path" "$model_url" || {
            echo -e "${RED}✘ Download failed${NC}"; return 1
        }
    else
        curl -L --progress-bar --silent --show-error -o "$model_path" "$model_url" || {
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
        case "$v" in
            *[!0-9]*) continue ;;  # Skip non-numeric
            *) total_vram=$((total_vram + v)) ;;
        esac
    done
    VRAM_GB=$((total_vram / 1024))
    
    echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC}"
    
    # Determine target model based on VRAM tiers
    if [ "$VRAM_GB" -ge "$TIER_32GB_MIN" ]; then
        MODEL_FILE="$GEMMA_32GB_FILE"
        MODEL_TIER="32GB-tier"
    elif [ "$VRAM_GB" -ge "$TIER_24GB_MIN" ]; then
        MODEL_FILE="$GEMMA_24GB_FILE"
        MODEL_TIER="24GB-tier"
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
    echo -e "${ICON_GEAR} Tier Cutoffs: 8GB>=${TIER_8GB_MIN}, 12GB>=${TIER_12GB_MIN}, 24GB>=${TIER_24GB_MIN}, 32GB>=${TIER_32GB_MIN}"
    echo -e "${ICON_GEAR} Tier Model: ${CYAN}${MODEL_FILE}${NC}"
    
    # Check if target model exists
    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${ICON_OK} Target Model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi
    
    # Target doesn't exist, look for local Gemma GGUF models
    echo -e "${YELLOW}⚠ Target model not found: $MODEL_FILE${NC}"
    echo -e "${CYAN}Scanning for available Gemma GGUF models...${NC}"

    local found_model
    found_model=$(find "$MODEL_STORAGE_DIR" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | grep -Ei 'gemma' | head -1)
    
    if [ -n "$found_model" ]; then
        MODEL_FILE=$(basename "$found_model")
        echo -e "${GREEN}✔ Using available model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi

    if [ "$STRICT_GEMMA_ONLY" = "true" ]; then
        echo -e "${RED}✘ No Gemma models found in $MODEL_STORAGE_DIR${NC}"
        return 1
    fi
    
    # No models found at all
    echo -e "${RED}✘ No GGUF models found in $MODEL_STORAGE_DIR${NC}"
    return 1
}

build_image() {
    image_check=$(docker images -q $IMAGE_NAME 2>/dev/null)
    if [ -z "$image_check" ]; then
        echo -e "${ICON_GEAR} Building Coder Image..."
        cat <<'EOF' > "$LOCAL_STACK_DIR/Dockerfile"
FROM node:20-bullseye-slim
RUN apt-get update && apt-get install -y \
    openscad tree android-tools-adb ripgrep curl git \
    --no-install-recommends && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code --quiet
WORKDIR /workspace
EOF
        docker build -t "$IMAGE_NAME" "$LOCAL_STACK_DIR" || {
            echo -e "${RED}✘ Docker build failed${NC}"; return 1
        }
    fi
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub..."

        # Write a concrete LiteLLM config file; env-only config can be missed depending on image version.
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

general_settings:
  enable_responses_api: false
EOF
    
    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$HUB_NETWORK" --gpus all --restart always \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/models" \
        "$LLAMA_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port 8080 \
        -ngl 99 -c "$CTX_PER_SLOT" --flash-attn 2>&1 | head -1
    
    docker run -d --name "$GLOBAL_PROXY_NAME" --network "$HUB_NETWORK" -p 4000:4000 --restart always \
        -v "$(to_host_path "$LOCAL_STACK_DIR/litellm_config.yaml"):/app/config.yaml:ro" \
        "$LITELLM_IMAGE" --config /app/config.yaml
}

start_workbench() {
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    docker run -d --name "$WORKBENCH" --network "$HUB_NETWORK" --privileged \
        -v "$(to_host_path "$(pwd)"):/workspace" \
        -v "$(to_host_path "$HOME/.npm-cache"):/root/.npm" \
        -v "$(to_host_path "$HOME/.claude-config"):/root/.config/claude-code" \
    -e ANTHROPIC_BASE_URL="http://$GLOBAL_PROXY_NAME:4000" \
        -e ANTHROPIC_API_KEY="sk-local-bypass" \
        "$IMAGE_NAME" /bin/bash -c "trap 'true' EXIT; while true; do sleep 3600; done"
}

ensure_workbench_running() {
    # Already running
    if [ -n "$(docker ps -q -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        return 0
    fi

    # Exists but stopped -> start it
    if [ -n "$(docker ps -aq -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
        docker start "$WORKBENCH" >/dev/null 2>&1 || return 1
        return 0
    fi

    # Missing -> create it
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
  spawn              Execute command in active workbench
  --status           Show GPU and engine status dashboard
  --setup-path       Create shell alias for this script
  --clean            Stop and remove all containers
  --help             Show this message
HELP
            exit 0
            ;;
        --status)
            exec "$(dirname "$(realpath "$0")")/ai-status.sh"
            ;;
        spawn)
            container="${WORKBENCH_PREFIX}-${PROJECT_ID}"
            cmd_exec="docker exec -it -u node -e CLAUDE_CODE_SIMPLE=1 $container claude --bare --model gemma-local --dangerously-skip-permissions"
            if [ "$IS_GITBASH" = "true" ]; then
                winpty $cmd_exec
            else
                eval $cmd_exec
            fi
            exit 0
            ;;
        --clean)
            echo -e "${CYAN}Tearing down Hub & Project Spokes...${NC}"
            docker stop $GLOBAL_ENGINE_NAME $GLOBAL_PROXY_NAME $(docker ps -q --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
            docker rm $GLOBAL_ENGINE_NAME $GLOBAL_PROXY_NAME $(docker ps -aq --filter "name=${WORKBENCH_PREFIX}-" 2>/dev/null) 2>/dev/null || true
            exit 0
            ;;
        --setup-path)
            rc_file="$HOME/.bashrc"
            [ "$SHELL" != "${SHELL%zsh}" ] && rc_file="$HOME/.zshrc"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo "alias $ALIAS_NAME='$(realpath "$0")'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' set. Run: source $rc_file"
            exit 0
            ;;
        "")
            # Continue to initialization
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo "Run: $0 --help"
            exit 1
            ;;
    esac
}

[ "$#" -gt 0 ] && handle_command "$@"

# --- [ IGNITION ] -------------------------------------------------------------

check_docker || { echo -e "${RED}✘ Docker initialization failed${NC}"; exit 1; }
# First pass establishes VRAM tier and current local model state.
detect_model || true

# Always evaluate download policy after VRAM is known.
download_model || { echo -e "${RED}✘ Model download failed${NC}"; exit 1; }

# Final pass selects the model to launch.
detect_model || { echo -e "${RED}✘ Model detection failed${NC}"; exit 1; }
build_image || { echo -e "${RED}✘ Image build failed${NC}"; exit 1; }

WORKBENCH="${WORKBENCH_PREFIX}-${PROJECT_ID}"

docker network create "$HUB_NETWORK" 2>/dev/null || true

if [ -z "$(docker ps -q -f name=$GLOBAL_ENGINE_NAME 2>/dev/null)" ]; then
    start_hub_engine || { echo -e "${RED}✘ Hub startup failed${NC}"; exit 1; }
fi

ensure_workbench_running || { echo -e "${RED}✘ Workbench startup failed${NC}"; exit 1; }

echo -ne "${CYAN}◈ Syncing VRAM Slots:${NC} "
retry_count=0
max_retries=90

# Wait for engine and proxy to be responsive
engine_ready=false
proxy_ready=false
while [ "$retry_count" -lt "$max_retries" ]; do
    if docker exec "$GLOBAL_ENGINE_NAME" curl -s -m 2 http://localhost:8080/v1/models 2>/dev/null | grep -q '"id"'; then
        engine_ready=true
    fi

    if curl -s -m 2 http://localhost:4000/v1/models 2>/dev/null | grep -q '"gemma-local"'; then
        proxy_ready=true
    fi

    if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then
        break
    fi

    retry_count=$((retry_count + 1))
    echo -ne "◈"
    sleep 2
done

if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then
    echo -e " ${GREEN}READY${NC}"
else
    echo -e " ${RED}TIMEOUT${NC}"
    echo -e "${RED}✘ Engine/Proxy failed to initialize after $((retry_count * 2)) seconds${NC}"
    echo -e "${CYAN}Diagnostics:${NC}"
    
    # Try to get engine container logs
    if docker ps -aq -f name="$GLOBAL_ENGINE_NAME" >/dev/null 2>&1 && [ -n "$(docker ps -aq -f name="$GLOBAL_ENGINE_NAME")" ]; then
        if [ -n "$(docker ps -q -f name="$GLOBAL_ENGINE_NAME")" ]; then
            echo "  Engine container is running. Last 30 logs:"
        else
            echo "  Engine container crashed/restarting. Last 30 logs:"
        fi
        docker logs "$GLOBAL_ENGINE_NAME" 2>&1 | tail -30 | sed 's/^/    /'
    else
        echo "  ${RED}✘ Engine container not found${NC}"
    fi
    
    # Check model file
    echo -e "${CYAN}  Model location: $MODEL_STORAGE_DIR/$MODEL_FILE${NC}"
    if [ -f "$MODEL_STORAGE_DIR/$MODEL_FILE" ]; then
        echo -e "${GREEN}  ✔ Model file exists${NC}"
    else
        echo -e "${RED}  ✘ Model file missing${NC}"
    fi

    if [ "$proxy_ready" != "true" ]; then
        echo "  Proxy container logs (last 30):"
        docker logs "$GLOBAL_PROXY_NAME" 2>&1 | tail -30 | sed 's/^/    /'
    fi
    
    exit 1
fi

echo -e "${ICON_GEAR} Attaching to workbench..."
if [ "$IS_GITBASH" = "true" ]; then
    winpty docker exec -it -u node -e CLAUDE_CODE_SIMPLE=1 "$WORKBENCH" claude --bare --model gemma-local --dangerously-skip-permissions
else
    docker exec -it -u node -e CLAUDE_CODE_SIMPLE=1 "$WORKBENCH" claude --bare --model gemma-local --dangerously-skip-permissions
fi