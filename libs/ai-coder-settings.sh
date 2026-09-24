#!/bin/bash
# ==============================================================================
# AI-CODER-SETTINGS.SH | Git Identity & Launch-Time Preference Resolution
# Loads settings.json preferences (git identity, network isolation, GPU mode,
# context/KV/offload tuning) into the globals the rest of the launcher expects,
# falling back to the family/model conf defaults when nothing is saved yet.
# ==============================================================================

# Load or prompt for git user identity, then store it for future runs.
# Sets GIT_USER_EMAIL and GIT_USER_NAME in the calling environment.
ensure_git_identity() {
    local git_email; git_email=$(read_setting git_email)
    local git_name;  git_name=$(read_setting git_name)
    [ -z "$git_email" ] && git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$git_name"  ] && git_name=$(git config  --global user.name  2>/dev/null || true)
    export GIT_USER_EMAIL="${git_email:-}"
    export GIT_USER_NAME="${git_name:-}"
}

# Resolve the inference engine behind the Hub: "llamacpp" (default) or
# "sglang". An exported ENGINE_BACKEND wins over the saved engine setting;
# anything unrecognised falls back to llamacpp. Also sets ENGINE_IMAGE, the
# image the engine container (and the model-volume sync helper) runs from.
# Called once by ai-coder-core.sh right after the prefs migration, so every
# later stage (menus, --setup, model selection, engine start) sees it.
ensure_engine_config() {
    local _engine="${ENGINE_BACKEND:-}"
    [ -n "$_engine" ] || _engine=$(read_setting engine)
    case "$_engine" in
        sglang) ENGINE_BACKEND=sglang;   ENGINE_IMAGE="$SGLANG_IMAGE" ;;
        *)      ENGINE_BACKEND=llamacpp; ENGINE_IMAGE="$LLAMA_IMAGE" ;;
    esac
}

# True when the Hub runs SGLang rather than llama.cpp.
engine_is_sglang() {
    [ "${ENGINE_BACKEND:-llamacpp}" = "sglang" ]
}

# Human-readable engine name for messages and menus.
engine_display_name() {
    engine_is_sglang && echo "SGLang" || echo "llama.cpp"
}

# Reads the SGLang static memory fraction (share of each GPU's total VRAM
# SGLang pre-allocates for weights + KV pool) into SGL_MEM_FRACTION.
# Anything outside 0.50-0.95 falls back to the default of 0.85.
ensure_sgl_config() {
    local _frac; _frac=$(read_setting sgl_mem_fraction)
    case "$_frac" in
        0.[5-8][0-9]|0.9[0-5]|0.[5-9]) SGL_MEM_FRACTION="$_frac" ;;
        *)                             SGL_MEM_FRACTION=0.85 ;;
    esac
}

# Load or prompt for network isolation preference, then store it for future runs.
# Sets NETWORK_INTERNAL in the calling environment.
ensure_network_config() {
    local isolated_net; isolated_net=$(read_setting isolated)
    [ "$isolated_net" = "yes" ] && NETWORK_INTERNAL=true || true
}

# Load or prompt for GPU mode preference, then store it for future runs.
# Sets GPU_MODE in the calling environment ("multi" or "single").
# Silently skips the prompt when only one GPU is present.
ensure_gpu_config() {
    GPU_MODE=$(read_setting gpu_mode)
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

# Sets MODEL_KV_TYPE (K cache, -ctk) and MODEL_KV_TYPE_V (V cache, -ctv)
# from the kv_mode setting (chosen in ai-coder --model):
#   default — the family's own MODEL_KV_TYPE for both (q8_0 for most)
#   asym    — q8_0 K / q4_0 V: keys are the quantization-sensitive side
#   q4      — q4_0 for both
# llama.cpp only compiles CUDA Flash Attention kernels for the K/V pairs
# listed in GGML_CUDA_FA_QUANTS (default q4_0-q4_0;q8_0-q8_0;f16-f16;
# bf16-bf16). A pair outside that list — like q8_0-q4_0 on the stock
# ghcr.io/ggml-org image — falls back to a far slower path, so asym also
# switches ENGINE_IMAGE to a locally built image that compiles the pair
# (see ensure_llama_asym_image).
#
# SGLang has no q4 or asymmetric KV cache and ignores the family's llama.cpp
# KV type: it uses "auto" (the model's own dtype) unless the FP8 KV cache
# setting is on.
ensure_kv_config() {
    if engine_is_sglang; then
        MODEL_KV_TYPE=auto
        [ "$(read_setting sgl_kv_fp8)" = "yes" ] && MODEL_KV_TYPE="fp8_e4m3"
        MODEL_KV_TYPE_V="$MODEL_KV_TYPE"
        return 0
    fi
    MODEL_KV_TYPE="${MODEL_KV_TYPE:-q8_0}"
    MODEL_KV_TYPE_V="${MODEL_KV_TYPE_V:-$MODEL_KV_TYPE}"
    case "$(read_setting kv_mode)" in
        q4)
            MODEL_KV_TYPE=q4_0; MODEL_KV_TYPE_V=q4_0 ;;
        asym)
            MODEL_KV_TYPE=q8_0; MODEL_KV_TYPE_V=q4_0
            ENGINE_IMAGE="$LLAMA_ASYM_IMAGE" ;;
    esac
}

# The KV cache type as one token for display and the engine_kv restart
# check: "q8_0" when K and V match, "q8_0/q4_0" (K/V) when they don't.
kv_type_label() {
    local _k="${MODEL_KV_TYPE:-q8_0}"
    local _v="${MODEL_KV_TYPE_V:-$_k}"
    [ "$_k" = "$_v" ] && echo "$_k" || echo "$_k/$_v"
}

ensure_overhead_config() {
    # Read the user-defined VRAM overhead reserve from settings.json.
    # Defaults to 1 if not set.
    local _vram_oh; _vram_oh=$(read_setting vram_overhead)
    # Ensure it's a number
    case "$_vram_oh" in
        *[!0-9]*) MODEL_VRAM_OVERHEAD_GB=1 ;;
        *)        MODEL_VRAM_OVERHEAD_GB="$_vram_oh" ;;
    esac
}

# Reads the CPU offload threshold from settings.json: the minimum percentage
# of a bigger model's weights that must fit in VRAM before it is selected
# with the remaining layers on CPU (see select_model_for_vram). 0 disables
# partial offload. Anything else outside 50-99 falls back to the default of
# 90 — below 50% the CPU carries most layers and generation crawls.
ensure_offload_config() {
    local _pct; _pct=$(read_setting cpu_offload_pct)
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
    # The container runs as root while every host-mounted path (workspace, npm
    # cache, tool config dirs) is owned by the host user, so without this git
    # refuses all operations with "dubious ownership". Only '*' works here:
    # matching is exact-path, with no parent/subdirectory inheritance.
    cat > "$gitcfg" <<GITCFG
[core]
    autocrlf = input
[safe]
    directory = *
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
