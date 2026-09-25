#!/bin/bash
# ==============================================================================
# AI-CODER-WATCH.SH | Detached Hub Watchers
# Executed (not sourced) in the background by schedule_hub_idle_stop and
# start_gpu_guard in ai-coder-core.sh, via nohup, so it outlives the launching
# session. Everything it needs arrives as arguments; jq is resolved here
# through ai-coder-jq.sh because the launcher's JQ_CMD may be a shell function
# (the Git Bash path wrapper) that a new process doesn't inherit.
#
# Usage:
#   ai-coder-watch.sh idle <minutes> <stamp> <state-file> <spoke-prefix> <container>...
#     After <minutes>, stop and remove the <container>s — unless state.json's
#     hub_idle_since no longer equals <stamp> (a launch or a newer session
#     exit re-armed it) or a spoke named <spoke-prefix>-* is running.
#   ai-coder-watch.sh gpu-guard <max-temp-c> <nvidia-smi> <state-file> <engine>
#     While <engine> runs, stop it once any GPU holds >= <max-temp-c> for three
#     consecutive 10s polls, recording the trip as engine_guard_trip.
# ==============================================================================
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-jq.sh"
resolve_jq_cmd || JQ_CMD="jq"

# Usage: _state_update <state-file> <jq-args>... — rewrite state.json through jq.
_state_update() {
    local _f="$1"; shift
    "$JQ_CMD" "$@" "$_f" > "$_f.tmp.$$" 2>/dev/null && mv "$_f.tmp.$$" "$_f" || rm -f "$_f.tmp.$$"
}

watch_idle() {
    local _min="$1" _stamp="$2" _state="$3" _prefix="$4"; shift 4
    sleep $(( _min * 60 ))
    local _cur
    _cur=$("$JQ_CMD" -r '(.hub_idle_since // empty)' "$_state" 2>/dev/null | tr -d '\r')
    [ "$_cur" = "$_stamp" ] || return 0
    [ -n "$(docker ps -q --filter "name=^/${_prefix}-" 2>/dev/null)" ] && return 0
    docker stop "$@" >/dev/null 2>&1
    docker rm   "$@" >/dev/null 2>&1
    _state_update "$_state" 'del(.hub_idle_since)'
}

watch_gpu_guard() {
    local _max="$1" _smi="$2" _state="$3" _engine="$4"
    local _strikes=0 _hot _t
    while docker ps -q -f "name=^/${_engine}\$" 2>/dev/null | grep -q .; do
        _hot=""
        for _t in $("$_smi" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d '\r'); do
            case "$_t" in ''|*[!0-9]*) ;; *) [ "$_t" -ge "$_max" ] && _hot="$_t" ;; esac
        done
        if [ -n "$_hot" ]; then _strikes=$(( _strikes + 1 )); else _strikes=0; fi
        if [ "$_strikes" -ge 3 ]; then
            docker stop "$_engine" >/dev/null 2>&1
            _state_update "$_state" --arg v "$(date '+%Y-%m-%d %H:%M') GPU held ${_hot}C (limit ${_max}C)" \
                '.engine_guard_trip = $v'
            return 0
        fi
        sleep 10
    done
}

case "${1:-}" in
    idle)      shift; watch_idle "$@" ;;
    gpu-guard) shift; watch_gpu_guard "$@" ;;
    *) echo "Usage: $(basename "$0") idle|gpu-guard ..." >&2; exit 2 ;;
esac
