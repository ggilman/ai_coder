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
# Sets IS_WSL, IS_GITBASH — shared with ai-coder-core.sh and offline/unbundle.sh
# so every entry point agrees on the platform.
source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-detect-env.sh"
# jq resolution for the network-isolation lookup below. Sourced (not executed)
# so only functions are defined; get_network_isolation_status resolves a jq
# (PATH > .assets) WITHOUT downloading - the dashboards run standalone and are
# read-only, so a missing jq degrades to "no".
source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-jq.sh"
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

# Reads the network-isolation preference directly from user/settings.json (both
# dashboards run standalone, without read_pref from ai-coder-env.sh). Resolves
# a jq (PATH > .assets) via ai-coder-jq.sh WITHOUT downloading - read-only
# context, so a missing jq or file degrades to "no".
# Usage: get_network_isolation_status <script_dir> — echoes "yes" or "no".
get_network_isolation_status() {
    local _settings_file="$1/user/settings.json"
    local _jq=""
    resolve_jq_cmd &>/dev/null && _jq="$JQ_CMD"
    local _val="no"
    if [ -n "$_jq" ] && [ -f "$_settings_file" ]; then
        _val=$("$_jq" -r '(.isolated // empty)' "$_settings_file" 2>/dev/null || echo "no")
    fi
    _val=$(printf '%s' "$_val" | tr -d '\r' | xargs)
    [ "$_val" = "yes" ] && echo "yes" || echo "no"
}

# Usage: get_engine_footprint <script_dir> — echoes the running model's size
# line, e.g. "7.3GB model, 4.0GB KV (128k q8_0), ~11.3GB VRAM", from the
# figures start_hub_engine records in user/state.json (estimates: compute
# buffers aren't included). Echoes nothing when they're unavailable (no jq,
# or an engine started before these were recorded).
get_engine_footprint() {
    local _state_file="$1/user/state.json" _jq="" _vals
    resolve_jq_cmd &>/dev/null && _jq="$JQ_CMD"
    [ -n "$_jq" ] && [ -f "$_state_file" ] || return 0
    _vals=$("$_jq" -r '[.engine_weights_bytes, .engine_kv_bytes, .engine_vram_bytes, .engine_ctx, .engine_kv]
        | map(. // "") | join(" ")' "$_state_file" 2>/dev/null | tr -d '\r') || return 0
    local _w _kv _vram _ctx _kvt
    read -r _w _kv _vram _ctx _kvt <<< "$_vals"
    case "${_w:-}${_kv:-}${_vram:-}" in ''|*[!0-9]*) return 0 ;; esac
    awk -v w="$_w" -v k="$_kv" -v v="$_vram" -v c="${_ctx:-0}" -v t="${_kvt:-?}" 'BEGIN{
        g=1073741824
        printf "%.1fGB model, %.1fGB KV (%dk %s), ~%.1fGB VRAM", w/g, k/g, c/1024, t, v/g
    }'
}
