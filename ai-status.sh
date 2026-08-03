#!/bin/bash

# ==============================================================================
# AI-STATUS-GUM.SH v4.6 | GPU & Engine Dashboard via Gum
# Monitors GPU utilization, VRAM, and AI Hub engine health.
# ==============================================================================
set -euo pipefail

# BULLETPROOF PATH RESOLUTION
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# --- [ AUTO-DEPENDENCY GUM BOOTSTRAP ] ----------------------------------------
GUM_DIR="$HOME/.ai_tool_setup_assets"
mkdir -p "$GUM_DIR"

GUM_EXE_NAME="gum"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    GUM_EXE_NAME="gum.exe"
fi

if ! command -v gum &> /dev/null && [ ! -f "$GUM_DIR/$GUM_EXE_NAME" ]; then
    echo "⚡ Bootstrapping status interface engine..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) GUM_ARCH="x86_64" ;;
        aarch64|arm64) GUM_ARCH="arm64" ;;
        *) GUM_ARCH="x86_64" ;;
    esac
    
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        PLATFORM="Windows"
        EXT=".zip"
    else
        PLATFORM="Linux"
        EXT=".tar.gz"
    fi
    
    DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/charmbracelet/gum/releases/latest" | grep "browser_download_url" | grep "${PLATFORM}_${GUM_ARCH}${EXT}" | cut -d '"' -f 4 | head -n 1)
    TMP_EXTRACT=$(mktemp -d)
    
    echo "📥 Downloading asset from: $DOWNLOAD_URL"
    if [ "$PLATFORM" == "Windows" ]; then
        curl -L "$DOWNLOAD_URL" -o "$TMP_EXTRACT/gum.zip"
        unzip -j -o "$TMP_EXTRACT/gum.zip" "gum.exe" -d "$GUM_DIR" || unzip -j -o "$TMP_EXTRACT/gum.zip" "*/gum.exe" -d "$GUM_DIR"
    else
        curl -L "$DOWNLOAD_URL" -o "$TMP_EXTRACT/gum.tar.gz"
        tar -xzf "$TMP_EXTRACT/gum.tar.gz" -C "$TMP_EXTRACT"
        find "$TMP_EXTRACT" -type f -name "gum" -exec mv {} "$GUM_DIR/" \;
    fi
    
    rm -rf "$TMP_EXTRACT"
    chmod +x "$GUM_DIR/$GUM_EXE_NAME"
    echo "✅ Setup interface engine ready!"
fi

if command -v gum &> /dev/null; then
    GUM_CMD="gum"
else
    GUM_CMD="$GUM_DIR/$GUM_EXE_NAME"
fi

# --- [ CONFIGURATION ] --------------------------------------------------------
readonly UPDATE_INTERVAL=2
readonly HEALTH_TIMEOUT=5
readonly ENGINE_NAME="ai-hub-engine"

IS_GITBASH=false
E_PAD="" # Terminal cursor hack to fix Git Bash Mintty emoji width rendering
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    IS_GITBASH=true
    E_PAD=$'\e[C' # ANSI escape to force the cursor 1 space to the right
fi

if [[ "$IS_GITBASH" == "true" ]]; then
    export SMI="nvidia-smi.exe"
else
    export SMI="nvidia-smi"
fi

# --- [ UTILITY FUNCTIONS ] ---------------------------------------------------

_ENGINE_TMP="/tmp/ai_status_engine_$$"
_SLOTS_TMP="/tmp/ai_status_slots_$$"
readonly SLOTS_TIMEOUT=2

get_gpu_stats() {
    if ! command -v "$SMI" &> /dev/null; then
        return 1
    fi
    "$SMI" --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null || return 1
}

get_engine_health() {
    local _old_opts; _old_opts=$(set +o | grep pipefail)
    set +o pipefail
    docker exec "$ENGINE_NAME" curl -s --max-time "$HEALTH_TIMEOUT" http://localhost:8080/health \
        > "$_ENGINE_TMP" 2>/dev/null || true
    eval "$_old_opts"
}

get_engine_slots() {
    local _old_opts; _old_opts=$(set +o | grep pipefail)
    set +o pipefail
    docker exec "$ENGINE_NAME" curl -s --max-time "$SLOTS_TIMEOUT" http://localhost:8080/slots \
        > "$_SLOTS_TMP" 2>/dev/null || true
    eval "$_old_opts"
}

get_model_name() {
    local _mtmp="/tmp/ai_status_model_$$"
    local _old_opts; _old_opts=$(set +o | grep pipefail)
    set +o pipefail
    docker exec "$ENGINE_NAME" curl -s --max-time "$HEALTH_TIMEOUT" http://localhost:8080/v1/models \
        > "$_mtmp" 2>/dev/null || true
    eval "$_old_opts"
    grep -o '"id":"[^"]*"' "$_mtmp" 2>/dev/null | head -1 | cut -d'"' -f4 || true
    rm -f "$_mtmp"
}

# Generates a standard colorized progress bar using ANSI-C quoting
make_progress_string() {
    local percentage=$1
    local width=${2:-20}
    if ! [[ "$percentage" =~ ^[0-9]+$ ]]; then percentage=0; fi
    
    local filled=$((percentage * width / 100))
    local empty=$((width - filled))
    
    # ANSI-C quoted color codes (resolves universally in bash memory)
    local c_grn=$'\e[32m'
    local c_yel=$'\e[33m'
    local c_red=$'\e[31m'
    local c_gry=$'\e[90m'
    local c_rst=$'\e[0m'
    
    local color="${c_grn}"
    if [ "$percentage" -gt 70 ]; then color="${c_yel}"; fi
    if [ "$percentage" -gt 90 ]; then color="${c_red}"; fi

    # Assemble progress bar track
    local bar="${color}"
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="${c_rst}${c_gry}"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="${c_rst}"
    
    printf "%s" "$bar"
}

# --- [ MAIN LOOP ] -----------------------------------------------------------
main() {
    clear
    trap "rm -f $_ENGINE_TMP $_SLOTS_TMP; exit" INT TERM EXIT
    while true; do
        printf "\033[H"

        # 1. RENDER HEADER
        $GUM_CMD style \
            --foreground 15 --background 57 \
            --bold --align center --width 74 --padding "0 2" \
            "🤖  AI HUB COMMAND CENTER"

        # 2. RENDER GPU CARDS (Vertical Stack Mode - Cyan Accented Borders)
        if gpu_data=$(get_gpu_stats); then
            if [ -z "$gpu_data" ]; then
                $GUM_CMD style \
                    --border rounded --border-foreground 1 \
                    --foreground 1 --align center --width 74 \
                    "✘  NVIDIA GPU details could not be queried (no data returned)"
            else
                while IFS=',' read -r id name util m_used m_total temp pwr; do
                    id=$(echo "$id" | xargs)
                    name=$(echo "$name" | xargs)
                    util=$(echo "$util" | xargs)
                    m_used=$(echo "$m_used" | xargs)
                    m_total=$(echo "$m_total" | xargs)
                    temp=$(echo "$temp" | xargs)
                    pwr=$(echo "$pwr" | xargs)

                    case "$m_total" in ''|*[!0-9]*) continue ;; esac
                    if [ "$m_total" -le 0 ]; then continue; fi
                    case "$m_used" in ''|*[!0-9]*) m_used=0 ;; esac
                    case "$util"   in ''|*[!0-9]*) util=0   ;; esac

                    m_perc=$((m_used * 100 / m_total))
                    
                    local vram_bar
                    vram_bar=$(make_progress_string "$m_perc" "40")
                    local util_bar
                    util_bar=$(make_progress_string "$util" "40")

                    # Formatting text with bold/dim tokens to preserve contrast
                    local card_content="📟  \e[1mGPU $id:\e[0m \e[36m$name\e[0m
📊  \e[1mVRAM:\e[0m $vram_bar $m_perc% (${m_used}/${m_total} MB)
🔥  \e[1mLoad:\e[0m $util_bar $util%
🌡️  \e[1mTemp:\e[0m \e[33m${temp}°C\e[0m   |  ⚡  \e[1mPower:\e[0m \e[33m${pwr}W\e[0m${E_PAD}"

                    $GUM_CMD style \
                        --border rounded --border-foreground 14 \
                        --width 74 --padding "0 1" \
                        "$(echo -e "$card_content")"
                        
                done <<< "$gpu_data"
            fi
        else
            $GUM_CMD style \
                --border rounded --border-foreground 1 \
                --foreground 1 --align center --width 74 \
                "✘  NVIDIA GPU details could not be queried or nvidia-smi is missing"
        fi

        # 3. RENDER ENGINE STATUS CARD (Dynamic Borders matching health state)
        get_engine_health
        health_raw=$(cat "$_ENGINE_TMP" 2>/dev/null || true)

        local engine_status_text=""
        if echo "$health_raw" | grep -q '"ok"'; then
            get_engine_slots
            slots_raw=$(cat "$_SLOTS_TMP" 2>/dev/null || true)

            if [ -n "$slots_raw" ]; then
                total_slots=$(echo "$slots_raw" | { grep -o '"id"' || true; } | wc -l | xargs)
                active_slots=$(echo "$slots_raw" | { grep -o '"is_processing":true' || true; } | wc -l | xargs)
                slot_info="$total_slots slot(s) | $active_slots active"
            else
                slot_info="busy processing tasks"
            fi

            model_name=$(get_model_name)
            
            engine_status_text="⚙️  \e[1mENGINE HUB:\e[0m   \e[32m🟢  ONLINE\e[0m${E_PAD}
📦  \e[1mActive Model:\e[0m \e[36m$model_name\e[0m
🔄  \e[1mCapacity:\e[0m     $slot_info"
            
            # --- RESTORED ORIGINAL ISOLATION LOGIC ---
            _iso_val="no"
            _settings_file="$SCRIPT_DIR/user/settings.conf"
            [ -f "$_settings_file" ] && _iso_val=$(grep '^isolated=' "$_settings_file" 2>/dev/null | cut -d= -f2- || echo "no")

            # Clean carriage returns
            _iso_val=$(echo "$_iso_val" | tr -d '\r' | xargs)

            if [ "$_iso_val" = "yes" ]; then
                engine_status_text="$engine_status_text
🔒  \e[1mNetwork:\e[0m      \e[33m⊘ Isolated\e[0m \e[90m(ai-engineering-isolated)\e[0m"
            else
                engine_status_text="$engine_status_text
🌐  \e[1mNetwork:\e[0m      \e[32m◎ Standard\e[0m \e[90m(ai-engineering-net)\e[0m"
            fi

            $GUM_CMD style \
                --border rounded --border-foreground 2 \
                --width 74 --padding "0 2" \
                "$(echo -e "$engine_status_text")"
        else
            if [ -n "$health_raw" ]; then
                engine_status_text="⚙️  \e[1mENGINE HUB:\e[0m   \e[33m🟡  LOADING MODEL...\e[0m${E_PAD}
⏳  Please wait while weights are allocated."
                $GUM_CMD style \
                    --border rounded --border-foreground 3 \
                    --width 74 --padding "0 2" \
                    "$(echo -e "$engine_status_text")"
            else
                engine_status_text="⚙️  \e[1mENGINE HUB:\e[0m   \e[31m🔴  OFFLINE / DISCONNECTED\e[0m${E_PAD}
❌  Verify that the '$ENGINE_NAME' container is running."
                $GUM_CMD style \
                    --border rounded --border-foreground 1 \
                    --width 74 --padding "0 2" \
                    "$(echo -e "$engine_status_text")"
            fi
        fi

        printf "\033[J"
        sleep "$UPDATE_INTERVAL"
    done
}

main
