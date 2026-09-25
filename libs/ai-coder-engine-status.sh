#!/bin/bash
# ==============================================================================
# AI-CODER-ENGINE-STATUS.SH | Hub Engine HTTP Probes
# Shared by ai-status.sh and ai-status-legacy.sh. Callers must define
# ENGINE_NAME, ENGINE_PORT, HEALTH_TIMEOUT, SLOTS_TIMEOUT, _ENGINE_TMP, and
# _SLOTS_TMP before calling these — kept as caller-provided globals (not
# parameters) to match how both dashboards already wire the temp-file paths
# into their trap cleanup.
#
# Online/offline is decided by /health, which llama.cpp answers immediately
# even while crunching a prompt. /slots must NOT be used for this: it is
# queued as an internal task the engine only services between decode batches,
# so under load it can take 30+ seconds — reading it as "offline" exactly
# when the engine is busiest. Slot detail is fetched separately, best-effort.
#
# The Hub engine may be llama.cpp or SGLang (the "engine" setting). The
# dashboards run standalone, without the launcher's pref I/O, so the engine
# is read from the running container's image instead (ENGINE_KIND, set by
# get_engine_health each refresh). SGLang differs in three ways handled here:
# its /health is an empty 200 (no JSON), it doesn't answer at all while
# loading, and it has no /slots — and its image may lack curl, so probes go
# through python3 there.
# ==============================================================================

ENGINE_KIND="llamacpp"

# Sets ENGINE_KIND from the engine container's image ("sglang" or "llamacpp").
detect_engine_kind() {
    local _img
    _img=$(docker inspect -f '{{.Config.Image}}' "$ENGINE_NAME" 2>/dev/null | tr -d '\r') || _img=""
    case "$_img" in
        *sglang*) ENGINE_KIND="sglang" ;;
        *)        ENGINE_KIND="llamacpp" ;;
    esac
}

# GET <url> <timeout-seconds> from inside the engine container; prints the
# body (SGLang: "HTTP <code>" on its own line first, via python3).
_engine_get() {
    if [ "$ENGINE_KIND" = "sglang" ]; then
        docker exec "$ENGINE_NAME" python3 -c '
import sys, urllib.request
try:
    r = urllib.request.urlopen(sys.argv[1], timeout=float(sys.argv[2]))
    print("HTTP %d" % r.status); sys.stdout.write(r.read().decode())
except Exception:
    pass' "$1" "$2" 2>/dev/null
    else
        docker exec "$ENGINE_NAME" curl -s --max-time "$2" "$1" 2>/dev/null
    fi
}

# set -o pipefail (active globally in both callers, unconditionally, and never
# toggled elsewhere) causes docker exec redirects to drop output. Disable
# pipefail locally for this call only, then restore it.
# For SGLang the result is normalized to llama.cpp's shapes, so the
# dashboards' checks work unchanged: {"status":"ok"} once /health answers
# 200, and a non-empty "loading" body while the container runs but the
# server isn't up yet (llama.cpp answers 503 + JSON during load itself).
get_engine_health() {
    set +o pipefail
    detect_engine_kind
    if [ "$ENGINE_KIND" = "sglang" ]; then
        if _engine_get "http://localhost:${ENGINE_PORT}/health" "$HEALTH_TIMEOUT" | grep -q '^HTTP 200'; then
            echo '{"status":"ok"}' > "$_ENGINE_TMP"
        elif [ -n "$(docker ps -q -f "name=^/${ENGINE_NAME}\$" 2>/dev/null)" ]; then
            echo '{"status":"loading"}' > "$_ENGINE_TMP"
        else
            : > "$_ENGINE_TMP"
        fi
    else
        _engine_get "http://localhost:${ENGINE_PORT}/health" "$HEALTH_TIMEOUT" > "$_ENGINE_TMP" || true
    fi
    set -o pipefail
}

# Fetches slot detail (short timeout — may legitimately fail while the engine
# is processing; callers must degrade gracefully, not report offline).
# SGLang has no /slots endpoint: the temp file is left empty, and the
# dashboards show "n/a" for capacity when ENGINE_KIND is sglang.
get_engine_slots() {
    set +o pipefail
    if [ "$ENGINE_KIND" = "sglang" ]; then
        : > "$_SLOTS_TMP"
    else
        _engine_get "http://localhost:${ENGINE_PORT}/slots" "$SLOTS_TIMEOUT" > "$_SLOTS_TMP" || true
    fi
    set -o pipefail
}

# Prints "<total> <active>" slot counts from the last get_engine_slots fetch,
# or nothing when it came back empty (engine busy, or SGLang).
get_engine_slot_counts() {
    local _raw _total _active
    _raw=$(cat "$_SLOTS_TMP" 2>/dev/null || true)
    [ -n "$_raw" ] || return 0
    _total=$(echo "$_raw" | { grep -o '"id"' || true; } | wc -l)
    _active=$(echo "$_raw" | { grep -o '"is_processing":true' || true; } | wc -l)
    echo "$(( _total )) $(( _active ))"
}

# Fetches the loaded model name from the engine's /v1/models endpoint
get_model_name() {
    local _mtmp="/tmp/ai_status_model_$$"
    set +o pipefail
    _engine_get "http://localhost:${ENGINE_PORT}/v1/models" "$HEALTH_TIMEOUT" > "$_mtmp" || true
    set -o pipefail
    grep -o '"id": *"[^"]*"' "$_mtmp" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true
    rm -f "$_mtmp"
}
