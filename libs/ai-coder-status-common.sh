#!/bin/bash
# ==============================================================================
# AI-CODER-STATUS-COMMON.SH | Shared Dashboard Data & Rendering Helpers
# Shared by ai-status.sh (gum) and ai-status-legacy.sh (plain-text fallback):
# platform/SMI detection, engine probe constants + temp-file paths (consumed by
# ai-coder-engine-status.sh, sourced by callers after this file), GPU stats
# fetch, a palette-agnostic progress bar renderer, and the network-isolation
# lookup. Each dashboard keeps its own visual theme (colors, box drawing) and
# calls into these for the shared mechanism. Self-contained like
# ai-coder-graphics.sh — no dependency on core.sh globals — since both callers
# source it standalone, before the full launch chain exists.
# ==============================================================================
[ "${_AI_CODER_STATUS_COMMON_LOADED:-}" = "1" ] && return 0
readonly _AI_CODER_STATUS_COMMON_LOADED=1

# --- [ PLATFORM DETECTION ] ---------------------------------------------------
readonly IS_GITBASH=$([[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && echo "true" || echo "false")
readonly SMI="$([[ "$IS_GITBASH" == "true" ]] && echo "nvidia-smi.exe" || echo "nvidia-smi")"

# --- [ ENGINE PROBE CONSTANTS ] -----------------------------------------------
# Consumed by libs/ai-coder-engine-status.sh, which both dashboards source
# after this file. $$ resolves to the caller's PID since this file is sourced,
# not executed, so the temp paths stay unique per dashboard process.
readonly UPDATE_INTERVAL=2
readonly HEALTH_TIMEOUT=5
readonly SLOTS_TIMEOUT=2
readonly ENGINE_NAME="ai-hub-engine"
# Mirrors ENGINE_PORT in libs/ai-coder-core.sh — kept as a separate constant
# here (not sourced from core.sh) since both dashboards run standalone.
readonly ENGINE_PORT=8080
# WSL2 workaround: docker exec output is lost when captured via $() command
# substitution, and 'timeout' wrapping docker exec also drops output. A fixed
# temp file plus curl's --max-time is used instead of the timeout binary.
_ENGINE_TMP="/tmp/ai_status_engine_$$"
_SLOTS_TMP="/tmp/ai_status_slots_$$"

# Fetches raw GPU stats via nvidia-smi. Returns 1 if the binary is missing or
# the query fails, so callers can render a clear "unavailable" state.
get_gpu_stats() {
    command -v "$SMI" >/dev/null 2>&1 || return 1
    "$SMI" --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null || return 1
}

# Renders one colorized progress bar. Palette-agnostic: callers pass their own
# escape codes so each dashboard keeps its own visual theme (legacy uses bold
# graphics.sh colors + DIM empty segments; the gum dashboard uses a thinner,
# non-bold palette) while sharing the fill/threshold logic.
# Usage: render_progress_bar <percent> <width> <color_ok> <color_warn> <color_crit> <color_empty> <color_reset>
# Threshold: >70% warn, >90% crit (matches both dashboards' prior behaviour).
render_progress_bar() {
    local percent="$1" width="$2" c_ok="$3" c_warn="$4" c_crit="$5" c_empty="$6" c_reset="$7"
    [[ "$percent" =~ ^[0-9]+$ ]] || percent=0

    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    local color="$c_ok"
    [ "$percent" -gt 70 ] && color="$c_warn"
    [ "$percent" -gt 90 ] && color="$c_crit"

    local bar="$color" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    bar+="${c_reset}${c_empty}"
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    bar+="${c_reset}"
    printf "%s" "$bar"
}

# Reads the network-isolation preference directly from settings.conf (both
# dashboards run standalone, without read_pref from ai-coder-env.sh).
# Usage: get_network_isolation_status <script_dir> — echoes "yes" or "no".
get_network_isolation_status() {
    local _settings_file="$1/user/settings.conf"
    local _val="no"
    [ -f "$_settings_file" ] && _val=$(grep '^isolated=' "$_settings_file" 2>/dev/null | cut -d= -f2- || echo "no")
    _val=$(printf '%s' "$_val" | tr -d '\r' | xargs)
    [ "$_val" = "yes" ] && echo "yes" || echo "no"
}
