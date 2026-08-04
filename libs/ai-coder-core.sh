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
DOCKER_BIN="${DOCKER_BIN:-}"   # default resolved below, after WIN_HOME is known
GLOBAL_ENGINE_NAME="ai-hub-engine"
GLOBAL_PROXY_NAME="ai-hub-proxy"
GLOBAL_WEBUI_NAME="ai-hub-webui"
OPEN_WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
OPEN_WEBUI_HOST_PORT=3000
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
# Placeholder credential sent to every agent/sidecar — the engine and proxy
# don't check auth, so this exists only to satisfy clients that require a
# non-empty API key. Single source of truth so it never drifts between agents.
LOCAL_API_KEY="sk-local-bypass"

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

# Resolve the default Docker Desktop launcher path. Docker Desktop may be a
# machine-wide install (Program Files) or a per-user install (AppData\Local).
# Candidates are probed in mount-path form; under WSL the match is converted
# to the Windows backslash form powershell.exe Start-Process expects (the Git
# Bash launch path converts with cygpath instead).
if [ -z "$DOCKER_BIN" ]; then
    _docker_c_root="/c"
    [ "$IS_WSL" = "true" ] && _docker_c_root="/mnt/c"
    for _docker_candidate in \
        "$_docker_c_root/Program Files/Docker/Docker/Docker Desktop.exe" \
        "$WIN_HOME/AppData/Local/Programs/DockerDesktop/frontend/Docker Desktop.exe"; do
        if [ -f "$_docker_candidate" ]; then
            DOCKER_BIN="$_docker_candidate"
            break
        fi
    done
    if [ -z "$DOCKER_BIN" ]; then
        # No install found — keep the historical Program Files default so the
        # failure mode (Start-Process error + manual-start hint) is unchanged.
        DOCKER_BIN="C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe"
    elif [ "$IS_WSL" = "true" ]; then
        DOCKER_BIN=$(wslpath -w "$DOCKER_BIN")
    fi
fi

# --- [ SUB-LIBRARIES ] --------------------------------------------------------
# Split out of this file for readability. Order matters only in that each
# depends on globals/colors set above and functions from files sourced before
# it — none of them are meant to be sourced standalone.
source "$SCRIPT_DIR/ai-coder-env.sh"        # path/shell utils, pref I/O, MCP JSON, update check
source "$SCRIPT_DIR/ai-coder-settings.sh"   # git identity + launch-time preference resolution
source "$SCRIPT_DIR/ai-coder-model.sh"      # docker preflight, VRAM budgeting, model select/download
source "$SCRIPT_DIR/ai-coder-workbench.sh"  # workbench + hub engine container lifecycle

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
        docker stop '$GLOBAL_ENGINE_NAME' '$GLOBAL_PROXY_NAME' '$GLOBAL_WEBUI_NAME' >/dev/null 2>&1
        docker rm   '$GLOBAL_ENGINE_NAME' '$GLOBAL_PROXY_NAME' '$GLOBAL_WEBUI_NAME' >/dev/null 2>&1
        sed -i '/^hub_idle_since=/d' '$STATE_FILE' 2>/dev/null
    " >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# Watchdog: while the engine runs, poll GPU temperatures and stop the engine
# if any GPU stays at/above MODEL_GPU_MAX_TEMP_C for three consecutive polls
# (~30s). A trip is recorded in state.conf (engine_guard_trip) and reported
# on the next launch. Set MODEL_GPU_MAX_TEMP_C=0 to disable. Best-effort by
# design: if the watcher dies with its terminal the engine simply runs
# unguarded, which was the behaviour before the guard existed.
start_gpu_guard() {
    local max_c="${MODEL_GPU_MAX_TEMP_C:-90}"
    case "$max_c" in ''|*[!0-9]*|0) return 0 ;; esac
    command -v "$SMI" >/dev/null 2>&1 || return 0
    nohup bash -c "
        strikes=0
        while docker ps -q -f name=^/${GLOBAL_ENGINE_NAME}\$ 2>/dev/null | grep -q .; do
            hot=''
            for t in \$($SMI --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d '\r'); do
                case \"\$t\" in ''|*[!0-9]*) ;; *) [ \"\$t\" -ge $max_c ] && hot=\$t ;; esac
            done
            if [ -n \"\$hot\" ]; then strikes=\$((strikes+1)); else strikes=0; fi
            if [ \"\$strikes\" -ge 3 ]; then
                docker stop '$GLOBAL_ENGINE_NAME' >/dev/null 2>&1
                sed -i '/^engine_guard_trip=/d' '$STATE_FILE' 2>/dev/null
                echo \"engine_guard_trip=\$(date '+%Y-%m-%d %H:%M') GPU held \${hot}C (limit ${max_c}C)\" >> '$STATE_FILE'
                exit 0
            fi
            sleep 10
        done
    " >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# After the engine reports ready, verify no GPU is at the edge of its VRAM.
# On Windows the WDDM driver does not fail an over-allocation — it silently
# pages VRAM to system RAM, which collapses generation speed and can freeze
# the whole desktop. 97%+ used right after load means the fit is
# oversubscribed even if llama.cpp started "successfully".
warn_if_vram_oversubscribed() {
    local _list; _list=$($SMI --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d '\r') || return 0
    local _u _t _pct _idx=0 _warned=false
    while IFS=', ' read -r _u _t _; do
        case "$_u" in ''|*[!0-9]*) _idx=$((_idx + 1)); continue ;; esac
        case "$_t" in ''|*[!0-9]*|0) _idx=$((_idx + 1)); continue ;; esac
        _pct=$(( _u * 100 / _t ))
        if [ "$_pct" -ge 97 ]; then
            echo -e "${YELLOW}⚠ GPU ${_idx} VRAM is ${_pct}% full (${_u}/${_t} MiB) — the model likely does not truly fit.${NC}"
            _warned=true
        fi
        _idx=$((_idx + 1))
    done <<< "$_list"
    if $_warned; then
        echo -e "${YELLOW}  Expect severe slowdown from driver VRAM paging. Reduce the context size,${NC}"
        echo -e "${YELLOW}  enable the low-VRAM KV cache, or drop a model tier before heavy use.${NC}"
    fi
    return 0
}

# Launch an Open WebUI container connected to the hub engine.
# Shared by the standalone webui agent (agents/ai-coder-webui.sh) and the
# sidecar started when webui_pref=yes.
# Usage: run_open_webui_container <container-name> [quiet]
# "quiet" disables Open WebUI's background task generations (title, tags,
# follow-ups, typing autocomplete): the engine runs with a single inference
# slot, and these fire several hidden completions per chat message that
# starve a concurrently running coding agent. The standalone webui agent
# omits it — with no agent competing for the slot they are harmless and
# useful.
run_open_webui_container() {
    local _name="$1" _mode="${2:-}"

    # Config is env-driven per boot (ENABLE_PERSISTENT_CONFIG=False) rather
    # than baked into the shared open-webui data volume on first boot — the
    # sidecar and standalone variants share that volume, so persisted config
    # from one mode would silently override the other's env settings.
    local _task_envs=(-e "ENABLE_PERSISTENT_CONFIG=False")
    if [ "$_mode" = "quiet" ]; then
        _task_envs+=(
            -e "ENABLE_TITLE_GENERATION=False"
            -e "ENABLE_TAGS_GENERATION=False"
            -e "ENABLE_FOLLOW_UP_GENERATION=False"
            -e "ENABLE_AUTOCOMPLETE_GENERATION=False"
            -e "ENABLE_RETRIEVAL_QUERY_GENERATION=False"
        )
    fi

    if ! docker image inspect "$OPEN_WEBUI_IMAGE" >/dev/null 2>&1; then
        echo -e "${CYAN}  Pulling $OPEN_WEBUI_IMAGE ...${NC}"
        docker pull "$OPEN_WEBUI_IMAGE" || {
            echo -e "${RED}✘ Failed to pull Open WebUI image${NC}"
            return 1
        }
    fi

    local _wb_network="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_network="$HUB_ISOLATED_NET"

    local _wb_http_proxy="${DOWNLOAD_PROXY:-}"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_http_proxy=""

    # Bind to localhost only — WEBUI_AUTH is disabled, so the UI must not be
    # reachable from the LAN.
    docker run -d --name "$_name" --network "$_wb_network" \
        -p "127.0.0.1:${OPEN_WEBUI_HOST_PORT}:8080" \
        -e "OPENAI_API_BASE_URL=http://${GLOBAL_ENGINE_NAME}:8080/v1" \
        -e "OPENAI_API_BASE_URLS=http://${GLOBAL_ENGINE_NAME}:8080/v1" \
        -e "OPENAI_API_KEY=${LOCAL_API_KEY}" \
        -e "OPENAI_API_KEYS=${LOCAL_API_KEY}" \
        -e "ENABLE_OPENAI_API=True" \
        -e "ENABLE_OLLAMA_API=False" \
        -e "WEBUI_AUTH=False" \
        "${_task_envs[@]}" \
        -e "http_proxy=${_wb_http_proxy}" \
        -e "https_proxy=${_wb_http_proxy}" \
        -e "HTTP_PROXY=${_wb_http_proxy}" \
        -e "HTTPS_PROXY=${_wb_http_proxy}" \
        -e "no_proxy=localhost,127.0.0.1,${GLOBAL_ENGINE_NAME}" \
        -e "NO_PROXY=localhost,127.0.0.1,${GLOBAL_ENGINE_NAME}" \
        -v "open-webui:/app/backend/data" \
        "$OPEN_WEBUI_IMAGE" > /dev/null
}

# Start the global Open WebUI sidecar alongside the selected coding agent.
# A failure degrades gracefully — the coding session continues without it.
start_webui_sidecar() {
    if [ -n "$(docker ps -q -f name=^/${GLOBAL_WEBUI_NAME}$ 2>/dev/null)" ]; then
        echo -e "${ICON_OK} Open WebUI already running at ${CYAN}http://localhost:${OPEN_WEBUI_HOST_PORT}${NC}"
        return 0
    fi
    docker rm "$GLOBAL_WEBUI_NAME" 2>/dev/null || true
    echo -e "${ICON_GEAR} Starting Open WebUI..."
    if run_open_webui_container "$GLOBAL_WEBUI_NAME" quiet; then
        echo -e "${ICON_OK} Open WebUI available at ${CYAN}http://localhost:${OPEN_WEBUI_HOST_PORT}${NC}"
    else
        echo -e "${YELLOW}⚠ Open WebUI failed to start — continuing without it.${NC}"
    fi
    return 0
}

stop_webui_sidecar() {
    docker stop "$GLOBAL_WEBUI_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_WEBUI_NAME" 2>/dev/null || true
}

stop_hub() {
    echo -e "${CYAN}◈ Shutting down Hub...${NC}"
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" "$GLOBAL_WEBUI_NAME" 2>/dev/null || true
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" "$GLOBAL_WEBUI_NAME" 2>/dev/null || true
    echo -e "${ICON_OK} Hub stopped."
}

teardown() {
    echo -e "${CYAN}Tearing down Hub & Project Spokes...${NC}"
    local _running; _running=$(docker ps -q  --filter "name=^/${WORKBENCH_PREFIX}-" 2>/dev/null || true)
    local _all;     _all=$(docker ps -aq --filter "name=^/${WORKBENCH_PREFIX}-" 2>/dev/null || true)
    # shellcheck disable=SC2086
    docker stop "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" "$GLOBAL_WEBUI_NAME" $( [ -n "$_running" ] && echo "$_running") 2>/dev/null || true
    # shellcheck disable=SC2086
    docker rm   "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" "$GLOBAL_WEBUI_NAME" $( [ -n "$_all" ]     && echo "$_all")     2>/dev/null || true
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
