#!/bin/bash

# ==============================================================================
# AI-STATUS-GUM.SH v4.7 | GPU & Engine Dashboard via Gum
# Monitors GPU utilization, VRAM, and AI Hub engine health.
# Includes automated offline fallback to ai-status-legacy.sh.
# ==============================================================================
set -euo pipefail

# BULLETPROOF PATH RESOLUTION
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# Source shared library for ensure_gum and other utilities
source "$SCRIPT_DIR/libs/ai-coder-setup.sh"
# Platform/SMI detection, engine-probe constants, get_gpu_stats,
# render_progress_bar, get_network_isolation_status — shared with
# ai-status-legacy.sh.
source "$SCRIPT_DIR/libs/ai-coder-status-common.sh"

# Fallback function to launch the legacy script
launch_legacy_fallback() {
    local legacy_script="$SCRIPT_DIR/ai-status-legacy.sh"
    echo "⚠️  Unable to initialize modern GUM interface (offline or download failed)."
    if [ -f "$legacy_script" ]; then
        echo "🔄 Launching legacy text-based dashboard..."
        sleep 2
        exec "$legacy_script"
    else
        echo "❌ Error: Legacy fallback script not found at: $legacy_script"
        exit 1
    fi
}

# --- [ AUTO-DEPENDENCY GUM BOOTSTRAP ] ----------------------------------------
# Ensure gum is available, then resolve the binary using library functions
ensure_gum || true
resolve_gum_cmd || launch_legacy_fallback

# --- [ CONFIGURATION ] --------------------------------------------------------
# IS_GITBASH/SMI, UPDATE_INTERVAL/HEALTH_TIMEOUT/ENGINE_NAME, and the engine
# temp-file paths come from ai-coder-status-common.sh (sourced above).
E_PAD="" # Terminal cursor hack to fix Git Bash Mintty emoji width rendering
[ "$IS_GITBASH" = "true" ] && E_PAD=$'\e[C' # ANSI escape to force the cursor 1 space to the right

# This dashboard's progress-bar palette — thin, non-bold colors (the legacy
# dashboard uses graphics.sh's bold palette instead). Passed into the shared
# render_progress_bar() from ai-coder-status-common.sh.
readonly C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_RED=$'\e[31m' C_GRY=$'\e[90m' C_RST=$'\e[0m'

# get_engine_health / get_engine_slots / get_model_name — shared with
# ai-status-legacy.sh (both read the globals defined by ai-coder-status-common.sh).
source "$SCRIPT_DIR/libs/ai-coder-engine-status.sh"

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
                    vram_bar=$(render_progress_bar "$m_perc" "40" "$C_GRN" "$C_YEL" "$C_RED" "$C_GRY" "$C_RST")
                    local util_bar
                    util_bar=$(render_progress_bar "$util" "40" "$C_GRN" "$C_YEL" "$C_RED" "$C_GRY" "$C_RST")

                    # Temp/power fields are padded to a fixed width so the
                    # E_PAD cursor-skip at end of line always lands on the
                    # same column across frames (see comment at E_PAD's
                    # definition) — otherwise a frame with fewer digits can
                    # leave a stale glyph from a wider previous frame behind.
                    local _temp_field _pwr_field
                    printf -v _temp_field "%-6s" "${temp}°C"
                    printf -v _pwr_field "%-10s" "${pwr}W"

                    # Formatting text with bold/dim tokens to preserve contrast
                    local card_content="📟  \e[1mGPU $id:\e[0m \e[36m$name\e[0m
📊  \e[1mVRAM:\e[0m $vram_bar $m_perc% (${m_used}/${m_total} MB)
🔥  \e[1mLoad:\e[0m $util_bar $util%
🌡️  \e[1mTemp:\e[0m \e[33m${_temp_field}\e[0m   |  ⚡  \e[1mPower:\e[0m \e[33m${_pwr_field}\e[0m${E_PAD}"

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

            # Status word is padded to a fixed width so the E_PAD cursor-skip
            # (see comment at its definition) always lands on the same column
            # across ONLINE/LOADING/OFFLINE frames — otherwise a shorter status
            # can leave a stale glyph from a longer previous status un-overwritten.
            local _status_word
            printf -v _status_word "%-22s" "ONLINE"
            engine_status_text="⚙️  \e[1mENGINE HUB:\e[0m   \e[32m🟢  ${_status_word}\e[0m${E_PAD}
📦  \e[1mActive Model:\e[0m \e[36m$model_name\e[0m
🔄  \e[1mCapacity:\e[0m     $slot_info"
            
            _iso_val=$(get_network_isolation_status "$SCRIPT_DIR")

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
                local _status_word
                printf -v _status_word "%-22s" "LOADING MODEL..."
                engine_status_text="⚙️  \e[1mENGINE HUB:\e[0m   \e[33m🟡  ${_status_word}\e[0m${E_PAD}
⏳  Please wait while weights are allocated."
                $GUM_CMD style \
                    --border rounded --border-foreground 3 \
                    --width 74 --padding "0 2" \
                    "$(echo -e "$engine_status_text")"
            else
                local _status_word
                printf -v _status_word "%-22s" "OFFLINE / DISCONNECTED"
                engine_status_text="⚙️  \e[1mENGINE HUB:\e[0m   \e[31m🔴  ${_status_word}\e[0m${E_PAD}
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
