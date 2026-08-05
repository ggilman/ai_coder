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
# ==============================================================================

# set -o pipefail (active globally in both callers) causes docker exec
# redirects to drop output. Disable pipefail locally for this call only.
get_engine_health() {
    local _old_opts; _old_opts=$(set +o | grep pipefail)
    set +o pipefail
    docker exec "$ENGINE_NAME" curl -s --max-time "$HEALTH_TIMEOUT" "http://localhost:${ENGINE_PORT}/health" \
        > "$_ENGINE_TMP" 2>/dev/null || true
    eval "$_old_opts"
}

# Fetches slot detail (short timeout — may legitimately fail while the engine
# is processing; callers must degrade gracefully, not report offline).
get_engine_slots() {
    local _old_opts; _old_opts=$(set +o | grep pipefail)
    set +o pipefail
    docker exec "$ENGINE_NAME" curl -s --max-time "$SLOTS_TIMEOUT" "http://localhost:${ENGINE_PORT}/slots" \
        > "$_SLOTS_TMP" 2>/dev/null || true
    eval "$_old_opts"
}

# Fetches the loaded model name from the engine's /v1/models endpoint
get_model_name() {
    local _mtmp="/tmp/ai_status_model_$$"
    local _old_opts; _old_opts=$(set +o | grep pipefail)
    set +o pipefail
    docker exec "$ENGINE_NAME" curl -s --max-time "$HEALTH_TIMEOUT" "http://localhost:${ENGINE_PORT}/v1/models" \
        > "$_mtmp" 2>/dev/null || true
    eval "$_old_opts"
    grep -o '"id":"[^"]*"' "$_mtmp" 2>/dev/null | head -1 | cut -d'"' -f4 || true
    rm -f "$_mtmp"
}
