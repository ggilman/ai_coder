#!/bin/bash
# ==============================================================================
# AI-CODER-MODEL.SH | VRAM Budgeting & Model Tier Selection
# Picks the model tier that fits the detected hardware before the Hub engine
# starts: VRAM/KV estimation, select_model_for_vram, detect_model, and the
# --family / --speed commands. Fetching the chosen tier is
# ai-coder-download.sh; Docker preflight and image pulls, ai-coder-docker.sh.
# ==============================================================================

# Usage: gpu_query <field[,field...]> — nvidia-smi's CSV (no header, no
# units) for those fields, one line per GPU, CRs stripped. Fails when
# nvidia-smi does.
gpu_query() {
    local _out
    _out=$("$SMI" --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null) || return 1
    printf '%s\n' "$_out" | tr -d '\r'
}

# Usage: gpu_query_ints <field> — gpu_query of one numeric field, one value
# per line, dropping non-numeric readings ("[N/A]" on some GPUs). Prints
# nothing when nvidia-smi fails.
gpu_query_ints() {
    local _v
    for _v in $(gpu_query "$1" || true); do
        case "$_v" in *[!0-9]*) ;; *) echo "$_v" ;; esac
    done
}

# KV cache sizing. A tier's MODEL_N_KV / MODEL_N_KV_SWA (MODEL_SGL_N_* for
# SGLang: cache elements per token, measured by --kv-probe from its GGUF
# header or its repo's config.json) give the exact geometry; KV size depends
# on the base model's architecture, not its quant, and one family often
# mixes several base models. Tiers without them fall back to the family's
# MODEL_KV_BYTES_PER_TOKEN, else a 96 KiB/token middle estimate for 8B-35B
# GQA models — always a q8_0 figure, scaled here for the KV type in effect.

# Usage: _estimate_kv_reserve_gb [candidate-index] — the KV-cache VRAM
# reserve in GB (rounded up) for the active context size and KV type.
_estimate_kv_reserve_gb() {
    echo $(( ($(_estimate_kv_bytes "$@") + 1073741823) / 1073741824 ))
}

# Usage: _estimate_kv_bytes [candidate-index] — estimated KV cache bytes for
# MODEL_CTX_SIZE at MODEL_KV_TYPE/MODEL_KV_TYPE_V, for the given candidate
# (default: the selected one, MODEL_SEL_INDEX). Also recorded at engine
# start (engine_kv_bytes) for the --status dashboard.
# SGLang: the context is capped at the model's maximum (MODEL_SGL_N_MAX_CTX,
# as _run_sglang_engine clamps it), and the figure is the pool that holds
# one full-length context — SGLang then fills whatever VRAM its memory
# fraction leaves, so this only steers the tier choice.
_estimate_kv_bytes() {
    local _i="${1:-${MODEL_SEL_INDEX:-}}" _geo="" _swa="" _max=""
    local _ctx="${MODEL_CTX_SIZE:-65536}" _k="${MODEL_KV_TYPE:-q8_0}"
    if [ -n "$_i" ]; then
        _geo=$(_cand_field "$_i" KV)
        _swa=$(_cand_field "$_i" KV_SWA)
        engine_is_sglang && _max=$(_cand_field "$_i" MAX_CTX)
    fi
    if [ -n "$_max" ] && [ "$_max" -lt "$_ctx" ] 2>/dev/null; then _ctx=$_max; fi
    local _bk _bv
    _bk=$(_kv_type_b32 "$_k")
    _bv=$(_kv_type_b32 "${MODEL_KV_TYPE_V:-$_k}")
    if [ -z "$_geo" ]; then
        # q8_0 bytes/token, half K and half V; q8_0 is 34 bytes per 32 elements.
        local _q8="${MODEL_KV_BYTES_PER_TOKEN:-98304}"
        echo $(( _ctx * (_q8 / 2) * (_bk + _bv) / 34 ))
        return
    fi
    local _total=$(( _ctx * (${_geo%%/*} * _bk + ${_geo#*/} * _bv) ))
    if [ -n "$_swa" ]; then
        local _win="${_swa##*@}" _sk="${_swa%%/*}" _sv="${_swa#*/}" _cells
        _sv="${_sv%@*}"
        if engine_is_sglang; then
            # SGLang's hybrid pool gives sliding-window layers a fixed share of
            # the full layers' tokens (--swa-full-tokens-ratio, default 0.8),
            # not a window-sized cache.
            _cells=$(( _ctx * 8 / 10 ))
        else
            # llama.cpp sizes their cache at the window per slot plus one
            # ubatch, capped at the context size.
            _cells=$(( _win * ${MODEL_MAX_SLOTS:-1} + ${MODEL_UBATCH_SIZE:-1024} ))
            [ "$_cells" -gt "$_ctx" ] && _cells=$_ctx
        fi
        _total=$(( _total + _cells * (_sk * _bk + _sv * _bv) ))
    fi
    echo $(( _total / 32 ))
}

# Usage: _kv_type_b32 <type> — cache bytes per 32 elements at <type> (the
# ggml block sizes). SGLang: "auto" is the model's own 16-bit dtype, and the
# fp8 types are one byte per element.
_kv_type_b32() {
    case "$1" in
        f32)                    echo 128 ;;
        f16|bf16|bfloat16|auto) echo 64 ;;
        q8_0)                   echo 34 ;;
        q5_1)                   echo 24 ;;
        q5_0)                   echo 22 ;;
        q4_1)                   echo 20 ;;
        q4_0|iq4_nl)            echo 18 ;;
        *)                      echo 32 ;;
    esac
}

# Single source of truth for the tier-fit test: a candidate fits when its
# WEIGHTS_GB plus its own KV cache reserve is <= the VRAM budget.
# WEIGHTS_GB=0 marks the unconditional fallback tier, which always fits.
# Both select_model_for_vram (pass 1) and print_model_candidates' Fit column
# call this, so the dry-run table and the real pick can't drift when the fit
# metric changes.
# Usage: _tier_fits <weights_gb> <budget_gb> <candidate-index>
_tier_fits() {
    [ "$1" -eq 0 ] || [ "$2" -ge $(( $1 + $(_estimate_kv_reserve_gb "$3") )) ]
}

# Candidate-list accessor shared by select_model_for_vram and
# print_model_candidates, so both engines use one selection algorithm.
# llama.cpp reads MODEL_<i>_<field> (GGUF files); SGLang reads the family's
# separate MODEL_SGL_<i>_<field> list (Hugging Face repos). For SGLang, FILE
# is derived from REPO — a snapshot directory under MODEL_STORAGE_DIR, e.g.
# sglang/Qwen--Qwen3-8B-AWQ — and URL is the repo id itself.
# Usage: _cand_field <index|COUNT> [FIELD]
_cand_field() {
    local i="$1" field="${2:-}" _v
    if engine_is_sglang; then
        if [ "$i" = "COUNT" ]; then echo "${MODEL_SGL_COUNT:-0}"; return; fi
        case "$field" in
            FILE)
                _v="MODEL_SGL_${i}_REPO"
                [ -n "${!_v:-}" ] && echo "sglang/${!_v//\//--}"
                ;;
            URL) _v="MODEL_SGL_${i}_REPO"; echo "${!_v:-}" ;;
            # Repos are pinned by revision instead of a checksum, and
            # layer counts only matter for llama.cpp's CPU offload.
            SHA256|LAYERS) ;;
            *) _v="MODEL_SGL_${i}_${field}"; echo "${!_v:-}" ;;
        esac
        return 0
    fi
    if [ "$i" = "COUNT" ]; then echo "${MODEL_COUNT:-0}"; return; fi
    _v="MODEL_${i}_${field}"
    echo "${!_v:-}"
}

# True when the selected model is fully on disk: the GGUF file for
# llama.cpp, or the snapshot directory's completion marker for SGLang
# (written last by download_sglang_model, so a partial download never counts).
model_present() {
    local _f="${1:-${MODEL_FILE:-}}"
    [ -n "$_f" ] || return 1
    if engine_is_sglang; then
        [ -f "$MODEL_STORAGE_DIR/$_f/$SGL_COMPLETE_MARKER" ]
    else
        [ -f "$MODEL_STORAGE_DIR/$_f" ]
    fi
}

# Walks the MODEL_1..MODEL_N candidate list defined by the active family conf,
# in priority order (best quality first), and selects the first entry whose
# MODEL_N_WEIGHTS_GB plus its own KV cache reserve fits within the supplied
# VRAM budget (draft and per-GPU overhead already subtracted). Sets
# MODEL_FILE, MODEL_URL, MODEL_SHA256, MODEL_TIER, MODEL_LAYERS, MODEL_NGL
# and MODEL_SEL_INDEX in the caller's environment.
#
# Partial CPU offload: when MODEL_CPU_OFFLOAD_PCT > 0, an entry ranked above
# the full-fit choice may be selected with some layers left on CPU, provided
# at least that percentage of its weights fits in the VRAM its KV cache
# leaves. The shortfall fraction equals the fraction of layers pushed to CPU, and a CPU layer is
# roughly 10x slower than a GPU layer, so slowdown ≈ 1 + 9 × fraction
# offloaded — the default 90% caps the worst case around half speed. Only
# entries whose MODEL_N_LAYERS differs from the full-fit choice qualify:
# quants of the same model share a layer count, and halving generation speed
# for a quant bump is a bad trade. MODEL_NGL is the -ngl value for llama.cpp
# (99 = all layers on GPU, the pre-offload behaviour). Under SGLang the
# MODEL_SGL_* list is walked instead (see _cand_field) and offload is skipped.
# The last candidate should have MODEL_N_WEIGHTS_GB=0 — it is always selected
# unconditionally as the fallback when nothing larger fits.
select_model_for_vram() {
    local vram="${1:-0}" i _w _l _room
    local _count; _count=$(_cand_field COUNT)
    MODEL_NGL=99

    # Pass 1: first entry that fits entirely in VRAM (the full-fit choice).
    # When no entry fits (malformed conf without a WEIGHTS_GB=0 fallback),
    # use the last defined candidate.
    local _full=0
    for (( i=1; i<=_count; i++ )); do
        [ -z "$(_cand_field "$i" FILE)" ] && break
        _w=$(_cand_field "$i" WEIGHTS_GB)
        if _tier_fits "${_w:-0}" "$vram" "$i"; then _full=$i; break; fi
    done
    [ "$_full" -eq 0 ] && _full=$(( _count > 0 ? _count : 1 ))
    local _sel=$_full

    # Pass 2: partial CPU offload — the best-ranked entry above the full-fit
    # choice wins if enough of it fits and it is a different model.
    # llama.cpp only: SGLang has no per-layer GPU/CPU split.
    local _pct="${MODEL_CPU_OFFLOAD_PCT:-90}"
    engine_is_sglang && _pct=0
    local _full_layers; _full_layers=$(_cand_field "$_full" LAYERS)
    _full_layers="${_full_layers:-0}"
    if [ "$_pct" -gt 0 ] 2>/dev/null; then
        for (( i=1; i<_full; i++ )); do
            _w=$(_cand_field "$i" WEIGHTS_GB); _w="${_w:-0}"
            _l=$(_cand_field "$i" LAYERS)
            [ "$_w" -gt 0 ] || continue
            [ -n "$_l" ] || continue
            [ "$_l" -ne "$_full_layers" ] || continue
            # The whole KV cache is reserved on GPU (conservative: the
            # offloaded layers' share of it actually lives in system RAM).
            _room=$(( vram - $(_estimate_kv_reserve_gb "$i") ))
            [ "$_room" -gt 0 ] || continue
            if [ $(( _room * 100 / _w )) -ge "$_pct" ]; then
                _sel=$i
                # Floor division is deliberately conservative: WEIGHTS_GB also
                # covers tensors that never offload per-layer (embeddings,
                # output head), so the true per-layer cost is slightly lower.
                MODEL_NGL=$(( _l * _room / _w ))
                break
            fi
        done
    fi

    MODEL_SEL_INDEX="$_sel"
    MODEL_FILE=$(_cand_field "$_sel" FILE)
    MODEL_URL=$(_cand_field "$_sel" URL)
    MODEL_SHA256=$(_cand_field "$_sel" SHA256)
    MODEL_TIER=$(_cand_field "$_sel" DESC); MODEL_TIER="${MODEL_TIER:-model-$_sel}"
    MODEL_LAYERS=$(_cand_field "$_sel" LAYERS)
    # Per-tier override for MTP families where only some quants/sizes bake in
    # built-in draft heads (e.g. Gemma 4's 12B/E2B don't) — blank/unset means
    # "has them", matching every MTP family conf before this field existed.
    MODEL_MTP=$(_cand_field "$_sel" MTP)
    # SGLang-only per-candidate extras (always empty under llama.cpp).
    MODEL_REVISION=$(_cand_field "$_sel" REVISION)
    MODEL_QUANT=$(_cand_field "$_sel" QUANT)
    MODEL_OVERRIDE_ARGS=$(_cand_field "$_sel" OVERRIDE_ARGS)
    MODEL_PATCH=$(_cand_field "$_sel" PATCH)
}

# True when speculative decoding should be used: the setting is on (default)
# and the active model family defines a draft model.
# Always false under SGLang: the family draft models are llama.cpp GGUFs.
spec_decode_enabled() {
    engine_is_sglang && return 1
    [ "$(read_setting spec_decode)" = "yes" ] && [ -n "${MODEL_DRAFT_FILE:-}" ]
}

# Format a byte count as a human-readable size.
# numfmt is not available in Git Bash — use awk for portability.
_human_size() {
    awk -v b="${1:-0}" 'BEGIN{
        s=b+0; u="B"
        if(s>=1073741824){s=s/1073741824; u="GiB"}
        else if(s>=1048576){s=s/1048576; u="MiB"}
        else if(s>=1024){s=s/1024; u="KiB"}
        printf "%.1f%s", s, u
    }'
}

# Audit the GPUs, reserve VRAM for the KV cache / draft model / per-GPU
# overhead, and select the model tier that fits (sets the MODEL_* vars via
# select_model_for_vram). Prints the budget breakdown.
detect_model() {
    local vram_list; vram_list=$(gpu_query memory.total,memory.free) || {
        echo -e "${RED}✘ nvidia-smi failed${NC}"; return 1
    }

    # Budget from FREE VRAM, not capacity: the display GPU permanently loses
    # VRAM to the desktop compositor and other apps, and budgeting from
    # capacity lets a model that "fits on paper" oversubscribe the card —
    # WDDM then silently pages VRAM to system RAM and the whole desktop
    # freezes/crawls. When the hub engine is already loaded, free VRAM
    # reflects its own model and is meaningless for tier selection — fall
    # back to capacity for that launch (the tier only matters if a config
    # change forces a restart, which frees the VRAM anyway).
    local _use_free=true
    container_running "$GLOBAL_ENGINE_NAME" && _use_free=false

    local total_vram=0 free_vram=0 gpu_idx=0 gpus_used=0 _t _f
    # SGLang only: per-GPU budget = min(free, total x mem-fraction), and
    # tensor parallelism splits evenly, so the smallest GPU sets the pace.
    local _sgl_min_mb=-1 _sgl_gpu
    while IFS=', ' read -r _t _f _; do
        case "$_t" in ''|*[!0-9]*) gpu_idx=$((gpu_idx + 1)); continue ;; esac
        # In single-GPU mode only count VRAM from GPU 0 so the tier selection
        # matches what will actually be available to the engine container.
        if [ "${GPU_MODE:-multi}" = "single" ] && [ "$gpu_idx" -gt 0 ]; then
            gpu_idx=$((gpu_idx + 1)); continue
        fi
        total_vram=$((total_vram + _t))
        case "$_f" in ''|*[!0-9]*) _f="$_t" ;; esac
        free_vram=$((free_vram + _f))
        if engine_is_sglang; then
            _sgl_gpu=$(awk -v t="$_t" -v m="${SGL_MEM_FRACTION:-0.85}" 'BEGIN{printf "%d", t*m}')
            if $_use_free && [ "$_f" -lt "$_sgl_gpu" ]; then _sgl_gpu="$_f"; fi
            if [ "$_sgl_min_mb" -lt 0 ] || [ "$_sgl_gpu" -lt "$_sgl_min_mb" ]; then _sgl_min_mb="$_sgl_gpu"; fi
        fi
        gpus_used=$((gpus_used + 1))
        gpu_idx=$((gpu_idx + 1))
    done <<< "$vram_list"
    VRAM_GB=$((total_vram / 1024))
    local budget_gb=$VRAM_GB
    if engine_is_sglang; then
        # TP size is a power of two (see sglang_tp_size); extra GPUs idle.
        local _tp; _tp=$(sglang_tp_size "$gpus_used")
        [ "$_sgl_min_mb" -lt 0 ] && _sgl_min_mb=0
        budget_gb=$(( _sgl_min_mb * _tp / 1024 ))
        gpus_used="$_tp"
        echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC} ${DIM}(SGLang: ${budget_gb}GB inside mem-fraction ${SGL_MEM_FRACTION:-0.85}, ${_tp} GPU)${NC}"
    elif $_use_free; then
        budget_gb=$((free_vram / 1024))
        echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC} ${DIM}(${budget_gb}GB free)${NC}"
    else
        echo -e "${ICON_GEAR} Hardware Audit: Detected ${BOLD}${VRAM_GB}GB Total VRAM${NC} ${DIM}(engine loaded — budgeting from capacity)${NC}"
    fi

    # Reserve VRAM before picking a tier — a model that fills the card leaves
    # no room for the KV cache at the chosen context size, causing OOM or RAM
    # spill (which makes inference crawl). Each tier's KV cache is sized for
    # that tier inside select_model_for_vram (see _tier_fits), since tiers of
    # one family can differ several-fold. The speculative-decoding draft model
    # occupies VRAM too when enabled, and each GPU loses a fixed overhead to
    # CUDA context, compute buffers, and desktop/display usage (see
    # MODEL_VRAM_OVERHEAD_GB).
    local draft_reserve=0 _draft_note=""
    if spec_decode_enabled; then
        draft_reserve="${MODEL_DRAFT_VRAM_GB:-1}"
        _draft_note="${draft_reserve}GB draft + "
    fi
    # Under SGLang the budget is already capped at the mem-fraction share of
    # each GPU; the (1 - fraction) SGLang leaves unallocated is its overhead
    # allowance, so the llama.cpp overhead reserve would double-count it.
    local overhead_reserve=$(( ${MODEL_VRAM_OVERHEAD_GB:-1} * gpus_used ))
    engine_is_sglang && overhead_reserve=0
    EFFECTIVE_VRAM_GB=$(( budget_gb - draft_reserve - overhead_reserve ))
    [ "$EFFECTIVE_VRAM_GB" -lt 0 ] && EFFECTIVE_VRAM_GB=0
    echo -e "${ICON_GEAR} VRAM Reserve: ${DIM}${_draft_note}${overhead_reserve}GB overhead (${gpus_used} GPU)${NC} → ${BOLD}${EFFECTIVE_VRAM_GB}GB${NC} for model + KV cache"

    select_model_for_vram "$EFFECTIVE_VRAM_GB"
    echo -e "${ICON_GEAR} Model: ${BOLD}${MODEL_TIER}${NC} ${DIM}(+ ~$(_estimate_kv_reserve_gb)GB KV: ${MODEL_CTX_LEVEL:-64k} ctx, $(kv_type_label))${NC}"
    if engine_is_sglang; then
        echo -e "${ICON_GEAR} Repo:  ${CYAN}${MODEL_URL}${NC}"
        # SGLang has no CPU offload, so a fallback tier (WEIGHTS_GB=0) larger
        # than the whole GPU budget can't load at all. MODEL_SGL_N_SIZE_GB
        # (optional, fallback entries only) gives its real size to catch that.
        # Sets MODEL_WONT_FIT so a real launch stops before a pointless download.
        MODEL_WONT_FIT=false
        local _sgl_size; _sgl_size=$(_cand_field "${MODEL_SEL_INDEX:-0}" SIZE_GB)
        if [ -n "$_sgl_size" ] && [ "$_sgl_size" -gt "$budget_gb" ] 2>/dev/null; then
            MODEL_WONT_FIT=true
            echo -e "${RED}⚠ Even this family's smallest SGLang model (~${_sgl_size}GB) is larger than SGLang's ${budget_gb}GB GPU budget — it will fail to load.${NC}"
            echo -e "${YELLOW}  Use llama.cpp for this family on this GPU (--setup), or pick another family (--model).${NC}"
        elif [ -n "$_sgl_size" ] && [ $(( _sgl_size + $(_estimate_kv_reserve_gb) )) -gt "$budget_gb" ] 2>/dev/null; then
            # It loads, but SGLang fills only the VRAM left over with KV cache.
            echo -e "${YELLOW}⚠ SGLang's KV pool won't hold a full ${MODEL_CTX_LEVEL:-64k} context with this model (~$(_estimate_kv_reserve_gb)GB KV needed) — lower the context level (--model), or use llama.cpp for this family (--setup).${NC}"
        fi
    else
        echo -e "${ICON_GEAR} File:  ${CYAN}${MODEL_FILE}${NC}"
    fi
    if [ "${MODEL_NGL:-99}" -lt 99 ]; then
        echo -e "${YELLOW}⚠ CPU offload: ${MODEL_NGL}/${MODEL_LAYERS} layers on GPU — running a bigger model at reduced speed (threshold ${MODEL_CPU_OFFLOAD_PCT:-90}%, disable via --model)${NC}"
    fi

    if [ -z "${MODEL_FILE:-}" ]; then
        echo -e "${RED}✘ No $(engine_display_name) model candidates defined for ${MODEL_FAMILY:-this family}${NC}"
        return 1
    fi
    if model_present; then
        echo -e "${ICON_OK} Target Model: ${CYAN}${MODEL_FILE}${NC}"
        return 0
    fi

    echo -e "${YELLOW}⚠ Target model not found locally — will download: ${CYAN}${MODEL_FILE}${NC}"
    return 0
}

# Print every tier defined by the active family conf as a dry-run table:
# each candidate's weights and KV cache vs the just-computed
# EFFECTIVE_VRAM_GB (Fit),
# the tier a launch would select (matching MODEL_FILE), and a note when
# that selection runs with partial CPU offload.
print_model_candidates() {
    local _count; _count=$(_cand_field COUNT)
    local _eff="${EFFECTIVE_VRAM_GB:-0}"
    local i _file _desc _w _l _kv _fit _mark
    echo -e "\n${BOLD}Model candidates${NC} ${DIM}($(engine_display_name), ${_eff}GB for model + KV after reserves)${NC}"
    echo -e "${DIM}  # | DESC | WeightsGB | KV GB | Layers | Fit${NC}"
    for (( i=1; i<=_count; i++ )); do
        _file=$(_cand_field "$i" FILE)
        [ -n "$_file" ] || break
        _desc=$(_cand_field "$i" DESC)
        _w=$(_cand_field "$i" WEIGHTS_GB); _w="${_w:-0}"
        _l=$(_cand_field "$i" LAYERS)
        _kv=$(_estimate_kv_reserve_gb "$i")
        if _tier_fits "$_w" "$_eff" "$i"; then _fit="yes"; else _fit="no"; fi
        _mark=""
        [ "$_file" = "${MODEL_FILE:-}" ] && _mark="  ${GREEN}◀ selected${NC}"
        printf '  %2d | %-58s | %9s | %5s | %6s | %s%s\n' "$i" "$_desc" "$_w" "$_kv" "$_l" "$_fit" "$_mark"
    done
    if [ "${MODEL_NGL:-99}" -lt 99 ]; then
        echo -e "  ${YELLOW}⚠ Selected tier runs with partial CPU offload: ${MODEL_NGL}/${MODEL_LAYERS} layers on GPU${NC}"
    fi
}

# Dry-run tier selection: report what a real launch would pick for a family
# without starting Docker, the Hub, or the workbench.
# Usage: cmd_models [family-key]
# Without a key, uses the saved family_pref (user/state.json).
cmd_models() {
    local family_key="${1:-}"
    [ -n "$family_key" ] || family_key=$(read_pref "$STATE_FILE" family_pref "")
    if [ -z "$family_key" ]; then
        echo -e "${RED}No model family selected yet. Pass a family key or run ${CYAN}--model${NC} first:${NC}"
        echo -e "${DIM}  $(basename "$0") --family <family-key>${NC}"
        return 1
    fi
    local _conf="$FAMILIES_DIR/${family_key}.conf"
    if [ ! -f "$_conf" ]; then
        echo -e "${RED}Error: Unknown model family '${family_key}'. Available families:${NC}"
        local _f
        for _f in "$FAMILIES_DIR"/*.conf; do
            [ -f "$_f" ] && echo -e "  ${DIM}- $(basename "$_f" .conf)${NC}"
        done
        return 1
    fi
    source "$_conf"
    require_family_supports_engine "$family_key" || return 1

    # Apply the same launch-time settings a real run resolves before
    # detect_model (see the IGNITION section in ai-coder), so the GPU
    # budget and VRAM reserves match what a launch would compute.
    ensure_sgl_config
    ensure_gpu_config
    ensure_ctx_config
    ensure_kv_config
    ensure_overhead_config
    ensure_offload_config

    if ! detect_model; then
        echo -e "${RED}✘ Model detection failed${NC}"
        return 1
    fi
    print_model_candidates
}

# Run the llama-bench generation-speed benchmark against the selected model
# in a one-shot container. Requires speed_tracking=yes.
# Usage: cmd_speed [family-key]
cmd_speed() {
    local family_key="${1:-}"
    [ -n "$family_key" ] || family_key=$(read_pref "$STATE_FILE" family_pref "")
    if [ -z "$family_key" ]; then
        echo -e "${RED}No model family selected yet. Pass a family key or run ${CYAN}--model${NC} first:${NC}"
        echo -e "${DIM}  $(basename "$0") --speed <family-key>${NC}"
        return 1
    fi
    if engine_is_sglang; then
        echo -e "${YELLOW}The llama-bench speed test is llama.cpp-only (the engine is set to SGLang).${NC}"
        echo -e "${DIM}  Switch engines with: $(basename "$0") --setup${NC}"
        return 1
    fi
    if [ "$(read_setting speed_tracking)" != "yes" ]; then
        echo -e "${YELLOW}Generation speed tracking is disabled.${NC}"
        echo -e "${DIM}  Enable it with: $(basename "$0") --setup${NC}"
        return 1
    fi
    local _conf="$FAMILIES_DIR/${family_key}.conf"
    if [ ! -f "$_conf" ]; then
        echo -e "${RED}Error: Unknown model family '${family_key}'. Available families:${NC}"
        local _f
        for _f in "$FAMILIES_DIR"/*.conf; do
            [ -f "$_f" ] && echo -e "  ${DIM}- $(basename "$_f" .conf)${NC}"
        done
        return 1
    fi
    source "$_conf"

    ensure_gpu_config
    ensure_ctx_config
    ensure_kv_config
    ensure_overhead_config
    ensure_offload_config

    if ! detect_model; then
        echo -e "${RED}✘ Model detection failed${NC}"
        return 1
    fi
    download_model || { echo -e "${RED}✘ Model download failed${NC}"; return 1; }

    pull_image_if_missing "$LLAMA_IMAGE_FULL" || return 1

    echo -e "${ICON_GEAR} Running generation-speed benchmark (llama-bench)..."
    local _models_src; _models_src="$(to_host_path "$MODEL_STORAGE_DIR")"
    local _gpus_flag="all" _cuda_env=()
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
        _cuda_env=(-e CUDA_VISIBLE_DEVICES=0)
    fi
    # The official full image ships its apps outside PATH (the entrypoint is an
    # absolute path), so resolve llama-bench from the known install locations
    # before falling back to a plain PATH lookup.
    docker run --rm --gpus "$_gpus_flag" "${_cuda_env[@]}" \
        -v "${_models_src}:/models" \
        -e BENCH_IMAGE="$LLAMA_IMAGE_FULL" \
        --entrypoint /bin/sh \
        "$LLAMA_IMAGE_FULL" \
        -c 'b=$(command -v llama-bench || true)
        [ -n "$b" ] || for c in /build/llama-bench /build/bin/llama-bench /usr/local/bin/llama-bench; do
            [ -x "$c" ] && { b="$c"; break; }
        done
        [ -n "$b" ] || b=$(find /build /usr/local /opt /app -maxdepth 3 -name llama-bench -type f 2>/dev/null | head -n 1)
        [ -n "$b" ] || { echo "llama-bench: not found in ${BENCH_IMAGE}" >&2; exit 127; }
        exec "$b" -m "$1" -ngl "$2" -b "$3" -ub "$4"' \
        sh "/models/$MODEL_FILE" "${MODEL_NGL:-99}" "${MODEL_BATCH_SIZE:-1024}" "${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}"
}
