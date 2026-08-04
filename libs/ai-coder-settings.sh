#!/bin/bash
# ==============================================================================
# AI-CODER-SETTINGS.SH | Git Identity & Launch-Time Preference Resolution
# Loads settings.conf preferences (git identity, network isolation, GPU mode,
# context/KV/offload tuning) into the globals the rest of the launcher expects,
# falling back to the family/model conf defaults when nothing is saved yet.
# ==============================================================================

# Load or prompt for git user identity, then store it for future runs.
# Sets GIT_USER_EMAIL and GIT_USER_NAME in the calling environment.
ensure_git_identity() {
    local git_email; git_email=$(read_pref "$SETTINGS_FILE" git_email "")
    local git_name;  git_name=$(read_pref  "$SETTINGS_FILE" git_name  "")
    [ -z "$git_email" ] && git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$git_name"  ] && git_name=$(git config  --global user.name  2>/dev/null || true)
    export GIT_USER_EMAIL="${git_email:-}"
    export GIT_USER_NAME="${git_name:-}"
}

# Load or prompt for network isolation preference, then store it for future runs.
# Sets NETWORK_INTERNAL in the calling environment.
ensure_network_config() {
    local isolated_net; isolated_net=$(read_pref "$SETTINGS_FILE" isolated no)
    [ "$isolated_net" = "yes" ] && NETWORK_INTERNAL=true || true
}

# Load or prompt for GPU mode preference, then store it for future runs.
# Sets GPU_MODE in the calling environment ("multi" or "single").
# Silently skips the prompt when only one GPU is present.
ensure_gpu_config() {
    GPU_MODE=$(read_pref "$SETTINGS_FILE" gpu_mode multi)
}

# Sets MODEL_CTX_LEVEL (and derives MODEL_CTX_SIZE) from the saved preference.
# Falls back to the default defined in ai-coder-model.conf when no pref is saved.
ensure_ctx_config() {
    local _level; _level=$(read_pref "$SETTINGS_FILE" ctx_level "")
    [ -n "$_level" ] && MODEL_CTX_LEVEL="$_level"
    # Re-derive MODEL_CTX_SIZE from the (possibly updated) level.
    case "${MODEL_CTX_LEVEL:-64k}" in
        4k)   MODEL_CTX_SIZE=4096   ;;
        8k)   MODEL_CTX_SIZE=8192   ;;
        16k)  MODEL_CTX_SIZE=16384  ;;
        32k)  MODEL_CTX_SIZE=32768  ;;
        64k)  MODEL_CTX_SIZE=65536  ;;
        128k) MODEL_CTX_SIZE=131072 ;;
        256k) MODEL_CTX_SIZE=262144 ;;
        *)    MODEL_CTX_SIZE=65536  ;;
    esac
}

# Sets MODEL_KV_TYPE to q4_0 (both K and V) from the low-VRAM KV cache
# preference (ai-coder --setup, off by default), overriding the family
# default. Matched K/V quant types use llama.cpp's fused CUDA Flash
# Attention kernel even on the stock ghcr.io/ggml-org image; mismatched
# types (the asymmetric approach this replaced) silently fall back to a
# CPU-bound path — see ggml-org/llama.cpp#20866 and #22411.
ensure_kv_config() {
    [ "$(read_pref "$SETTINGS_FILE" kv_q4 no)" = "yes" ] && MODEL_KV_TYPE="q4_0" || true
}

ensure_overhead_config() {
    # Read the user-defined VRAM overhead reserve from settings.conf.
    # Defaults to 1 if not set.
    local _vram_oh; _vram_oh=$(read_pref "$SETTINGS_FILE" vram_overhead 1)
    # Ensure it's a number
    case "$_vram_oh" in
        *[!0-9]*) MODEL_VRAM_OVERHEAD_GB=1 ;;
        *)        MODEL_VRAM_OVERHEAD_GB="$_vram_oh" ;;
    esac
}

# Reads the CPU offload threshold from settings.conf: the minimum percentage
# of a bigger model's weights that must fit in VRAM before it is selected
# with the remaining layers on CPU (see select_model_for_vram). 0 disables
# partial offload. Anything else outside 50-99 falls back to the default of
# 90 — below 50% the CPU carries most layers and generation crawls.
ensure_offload_config() {
    local _pct; _pct=$(read_pref "$SETTINGS_FILE" cpu_offload_pct 90)
    case "$_pct" in
        0)           MODEL_CPU_OFFLOAD_PCT=0 ;;
        ''|*[!0-9]*) MODEL_CPU_OFFLOAD_PCT=90 ;;
        *)
            if [ "$_pct" -ge 50 ] && [ "$_pct" -le 99 ]; then
                MODEL_CPU_OFFLOAD_PCT="$_pct"
            else
                MODEL_CPU_OFFLOAD_PCT=90
            fi
            ;;
    esac
}

# Write a ~/.gitconfig-container file that gets mounted into containers as
# /root/.gitconfig so git commands in any repo (including newly init'd ones)
# pick up the correct author identity.
# Always writes the file — run_workbench bind-mounts it unconditionally, and a
# missing mount source would make Docker create it as a root-owned directory.
ensure_container_gitconfig() {
    local gitcfg="$HOME/.gitconfig-container"
    # Recover from a previous run where Docker created this path as a directory.
    if [ -d "$gitcfg" ]; then
        rm -rf "$gitcfg" 2>/dev/null || sudo rm -rf "$gitcfg" 2>/dev/null || true
    fi
    # Normalize CRLF→LF inside containers (Windows host mounts files with CRLF).
    cat > "$gitcfg" <<GITCFG
[core]
    autocrlf = input
GITCFG
    if [ -n "${GIT_USER_EMAIL:-}" ] || [ -n "${GIT_USER_NAME:-}" ]; then
        local email="${GIT_USER_EMAIL:-developer@localhost}"
        local name="${GIT_USER_NAME:-Developer}"
        # Escape backslashes and double-quotes for git config quoted-value syntax.
        # Wrapping in double quotes makes # and ; safe (not treated as comments).
        email="${email//\\/\\\\}"; email="${email//\"/\\\"}"
        name="${name//\\/\\\\}";   name="${name//\"/\\\"}"
        cat >> "$gitcfg" <<GITCFG
[user]
    email = "${email}"
    name = "${name}"
GITCFG
    fi
}

# Write identity into the local repo's .git/config (host-side).
# The workspace volume mount means the container sees this immediately.
# Skips gracefully if not inside a git repo or if already configured.
apply_git_identity() {
    if ! git -C "$(pwd)" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi
    local cur_email; cur_email=$(git -C "$(pwd)" config --local user.email 2>/dev/null || true)
    local cur_name;  cur_name=$(git  -C "$(pwd)" config --local user.name  2>/dev/null || true)
    [ -z "$cur_email" ] && [ -n "${GIT_USER_EMAIL:-}" ] && git -C "$(pwd)" config --local user.email "$GIT_USER_EMAIL"
    [ -z "$cur_name"  ] && [ -n "${GIT_USER_NAME:-}"  ] && git -C "$(pwd)" config --local user.name  "$GIT_USER_NAME"
    # Normalize CRLF→LF on checkout inside the container (Windows host mounts files with CRLF).
    # 'input' strips CR on add but never introduces CR on checkout — safe for all platforms.
    git -C "$(pwd)" config --local core.autocrlf input 2>/dev/null || true
    [ -n "${GIT_USER_NAME:-}" ] && printf "%s Git identity: %s%s${NC} <%s>\n" "${ICON_OK}" "${CYAN}" "${GIT_USER_NAME}" "${GIT_USER_EMAIL}"
    return 0
}
