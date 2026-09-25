#!/bin/bash
# ==============================================================================
# AI-CODER-SGLANG.SH | SGLang Engine Support
# Everything specific to running the Hub engine on SGLang instead of
# llama.cpp (selected by the "engine" setting, see ensure_engine_config):
# family/engine compatibility checks, Hugging Face snapshot download, tensor-
# parallel sizing, and the engine container's docker run. The shared engine
# lifecycle (start_hub_engine, restart detection, readiness poll) stays in
# ai-coder-workbench.sh and calls into this file where the engines differ.
#
# SGLang serves models as Hugging Face repos (safetensors, AWQ/GPTQ/FP8/
# MXFP4), not GGUF, so each family conf carries a separate, optional
# MODEL_SGL_* candidate list (see config/ai-coder-model.conf). Families
# without one are hidden from the family menu while SGLang is selected.
# ==============================================================================

# Written into a snapshot directory as the very last download step, so a
# directory without it is always an incomplete download (see model_present).
SGL_COMPLETE_MARKER=".ai-coder-complete"

# True when <conf-file> defines an SGLang candidate list. Greps rather than
# sources so the family menu can filter every conf cheaply.
family_conf_supports_sglang() {
    grep -q '^MODEL_SGL_COUNT=' "$1" 2>/dev/null
}

# After a family conf is sourced: under SGLang, fail with guidance when the
# family has no SGLang candidates. Returns 0 under llama.cpp (every family
# supports it). Usage: require_family_supports_engine <family-key>
require_family_supports_engine() {
    engine_is_sglang || return 0
    [ -n "${MODEL_SGL_COUNT:-}" ] && return 0
    echo -e "${RED}✘ The ${MODEL_FAMILY:-$1} family has no SGLang models.${NC}"
    echo -e "${YELLOW}  Pick another family with: $(basename "$0") --model${NC}"
    echo -e "${YELLOW}  or switch the engine back to llama.cpp with: $(basename "$0") --setup${NC}"
    return 1
}

# Tensor-parallel size for <gpu-count> GPUs: SGLang shards every layer evenly
# across TP ranks and the attention-head count must divide by the TP size,
# so round down to a power of two (3 GPUs -> 2; the third idles).
sglang_tp_size() {
    local n="${1:-1}" tp=1
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    while [ $(( tp * 2 )) -le "$n" ]; do tp=$(( tp * 2 )); done
    echo "$tp"
}

# Multi-GPU arg resolution for SGLang, called from _resolve_engine_gpu_args
# in place of llama.cpp's --tensor-split. Sets _tp_args (and, when fewer GPUs
# are used than exist, _cuda_env) in the caller's scope. Warns when the GPUs'
# VRAM differs by more than 10%: an even split means the smallest card caps
# what every card can hold.
_resolve_sglang_tp_args() {
    local _vals=() _v
    mapfile -t _vals < <(gpu_query_ints memory.total)
    local _n="${#_vals[@]}"
    [ "$_n" -gt 0 ] || _n=1
    local _tp; _tp=$(sglang_tp_size "$_n")
    _tp_args=(--tp "$_tp")
    if [ "$_tp" -lt "$_n" ]; then
        local _ids; _ids=$(seq -s, 0 $(( _tp - 1 )))
        _cuda_env=(-e "CUDA_VISIBLE_DEVICES=$_ids")
    fi
    if [ "$_tp" -gt 1 ]; then
        echo -e "${ICON_GEAR} GPU Mode: ${GREEN}Multi — tensor parallel across ${_tp} GPUs${NC}"
        local _min="${_vals[0]}" _max="${_vals[0]}"
        for _v in "${_vals[@]:0:$_tp}"; do
            [ "$_v" -lt "$_min" ] && _min="$_v"
            [ "$_v" -gt "$_max" ] && _max="$_v"
        done
        if [ $(( (_max - _min) * 100 / _max )) -gt 10 ]; then
            echo -e "${YELLOW}⚠ GPUs have unequal VRAM (${_min}-${_max} MiB): SGLang splits evenly, so each is capped at the smallest card.${NC}"
        fi
        [ "$_tp" -lt "$_n" ] && echo -e "${YELLOW}⚠ ${_n} GPUs found — SGLang needs a power-of-two count, using the first ${_tp}.${NC}"
    fi
}

# Download the selected Hugging Face repo snapshot into
# MODEL_STORAGE_DIR/<MODEL_FILE> (a directory). Runs huggingface_hub's
# snapshot_download inside the SGLang image (which ships it), so the host
# needs no Python. Downloads into <dir>.part — kept across interruptions,
# since snapshot_download resumes — then writes the completion marker and
# renames into place. Revision pins (MODEL_SGL_N_REVISION) stand in for the
# GGUF path's sha256 check. HF_TOKEN, if set (e.g. in ~/.ai-coder-env), is
# passed through for gated repos.
download_sglang_model() {
    if [ -z "${MODEL_FILE:-}" ] || [ -z "${MODEL_URL:-}" ]; then
        select_model_for_vram "${EFFECTIVE_VRAM_GB:-${VRAM_GB:-0}}"
    fi
    model_present && return 0
    [ -n "${MODEL_URL:-}" ] || { echo -e "${RED}✘ Missing Hugging Face repo for ${MODEL_FILE:-model}${NC}"; return 1; }

    pull_image_if_missing "$SGLANG_IMAGE" || return 1

    local dest="$MODEL_STORAGE_DIR/$MODEL_FILE" part="$MODEL_STORAGE_DIR/$MODEL_FILE.part"
    mkdir -p "$part"

    echo -e "${ICON_GEAR} Downloading ${MODEL_TIER:-$MODEL_URL} ${DIM}(${MODEL_URL}${MODEL_REVISION:+@${MODEL_REVISION:0:12}})${NC}..."
    echo -e "${CYAN}Downloading to: $dest${NC}"

    local _proxy_env=()
    if [ -n "${DOWNLOAD_PROXY:-}" ]; then
        local _p; _p=$(resolve_http_proxy_url)
        echo -e "${CYAN}Using proxy: $DOWNLOAD_PROXY${NC}"
        _proxy_env=(-e "HTTPS_PROXY=$_p" -e "HTTP_PROXY=$_p" -e "https_proxy=$_p" -e "http_proxy=$_p")
    fi
    # "-e HF_TOKEN" (no value) copies it from this process's environment, so
    # the token never appears on the docker command line.
    local _token_env=()
    [ -n "${HF_TOKEN:-}" ] && _token_env=(-e HF_TOKEN)

    local _name="ai-coder-model-download"
    docker rm -f "$_name" >/dev/null 2>&1 || true
    # The repo's original/ and metal/ folders (e.g. gpt-oss) duplicate the
    # weights in formats SGLang doesn't load; GGUFs are llama.cpp's.
    HF_TOKEN="${HF_TOKEN:-}" docker run --rm --name "$_name" --entrypoint python3 \
        -e HF_HUB_DISABLE_PROGRESS_BARS=1 "${_proxy_env[@]}" "${_token_env[@]}" \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/models" \
        "$SGLANG_IMAGE" -c '
import sys
from huggingface_hub import snapshot_download
dest, repo, rev = sys.argv[1], sys.argv[2], (sys.argv[3] or None)
snapshot_download(repo_id=repo, revision=rev, local_dir=dest,
                  ignore_patterns=["original/*", "metal/*", "*.gguf"])
' "/models/$MODEL_FILE.part" "$MODEL_URL" "${MODEL_REVISION:-}" &
    local _dl_pid=$!

    local _sz
    while kill -0 "$_dl_pid" 2>/dev/null; do
        _sz=$(du -sb "$part" 2>/dev/null | cut -f1) || _sz=0
        printf "\r  Downloaded: %-12s" "$(_human_size "${_sz:-0}")"
        sleep 3
    done
    printf "\n"
    if ! wait "$_dl_pid"; then
        echo -e "${RED}✘ Download failed${NC} ${DIM}(partial download kept in $(basename "$part") — the next launch resumes it)${NC}"
        return 1
    fi

    touch "$part/$SGL_COMPLETE_MARKER"
    rm -rf "$dest"
    mv "$part" "$dest"
    echo -e "${GREEN}✔ Model downloaded successfully${NC}"
}

# docker run for the SGLang engine. Called by start_hub_engine after the
# shared prelude has resolved _hub_net, _gpus_flag, _cuda_env, _tp_args,
# _port_args and _models_src (all in the caller's scope).
#
# HF_HUB_OFFLINE=1: the snapshot directory already holds the weights,
# tokenizer and chat template, so the engine never needs the network — which
# is what keeps the network-isolation setting working.
# --ipc=host: SGLang's worker processes (and NCCL, with --tp > 1) share
# tensors through /dev/shm, which Docker's 64MB default would starve.
# --served-model-name matches the model id every agent derives from
# MODEL_FILE's basename. SGL_EXTRA_ARGS (env, word-split) is an escape
# hatch for any other launch_server flag.
#
# MODEL_PATCH (a candidate's MODEL_SGL_N_PATCH) names a bash snippet in
# config/sglang-patches/ that works around an SGLang bug for that model. It
# runs inside the container ahead of launch_server; since the container is
# recreated on every engine start, the edit never outlives the run.
_run_sglang_engine() {
    local _model_name="${MODEL_FILE##*/}"
    local _parser_args=()
    [ -n "${MODEL_SGL_TOOL_PARSER:-}" ]      && _parser_args+=(--tool-call-parser "$MODEL_SGL_TOOL_PARSER")
    [ -n "${MODEL_SGL_REASONING_PARSER:-}" ] && _parser_args+=(--reasoning-parser "$MODEL_SGL_REASONING_PARSER")
    local _quant_args=()
    [ -n "${MODEL_QUANT:-}" ] && _quant_args=(--quantization "$MODEL_QUANT")
    [ -n "${MODEL_OVERRIDE_ARGS:-}" ] && _quant_args+=(--json-model-override-args "$MODEL_OVERRIDE_ARGS")
    local _extra_args=()
    # shellcheck disable=SC2206
    [ -n "${SGL_EXTRA_ARGS:-}" ] && _extra_args=(${SGL_EXTRA_ARGS})
    local _launch=(--entrypoint python3 "$SGLANG_IMAGE" -m sglang.launch_server)
    if [ -n "${MODEL_PATCH:-}" ]; then
        local _patch_file="$CONFIG_DIR/sglang-patches/${MODEL_PATCH}.sh"
        if [ ! -f "$_patch_file" ]; then
            echo -e "${RED}✘ SGLang patch not found: ${_patch_file}${NC}" >&2
            return 1
        fi
        _launch=(--entrypoint bash "$SGLANG_IMAGE" -c
            "$(tr -d '\r' < "$_patch_file")"$'\n''exec python3 -m sglang.launch_server "$@"' sglang)
    fi

    # Unlike llama.cpp, SGLang refuses to start when --context-length exceeds
    # the model's trained maximum (e.g. 40960 for Qwen3), so clamp to the
    # snapshot's config.json. Local only: MODEL_CTX_SIZE itself stays the
    # user's level so the engine_ctx restart check doesn't flap.
    local _ctx="$MODEL_CTX_SIZE" _max
    _max=$("${JQ_CMD:-jq}" -r '.max_position_embeddings // .text_config.max_position_embeddings // empty' \
        "$MODEL_STORAGE_DIR/$MODEL_FILE/config.json" 2>/dev/null | tr -d '\r') || _max=""
    case "$_max" in ''|*[!0-9]*) ;; *)
        if [ "$_ctx" -gt "$_max" ]; then
            echo -e "${YELLOW}◈ Context ${MODEL_CTX_LEVEL:-$_ctx} exceeds this model's maximum — using ${_max} tokens.${NC}"
            _ctx="$_max"
        fi ;;
    esac

    echo -e "${ICON_GEAR} Engine: ${GREEN}SGLang${NC} ${DIM}(mem-fraction ${SGL_MEM_FRACTION:-0.85}, KV ${MODEL_KV_TYPE:-auto}${MODEL_SGL_TOOL_PARSER:+, tool parser ${MODEL_SGL_TOOL_PARSER}}${MODEL_PATCH:+, patch ${MODEL_PATCH}})${NC}"

    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$_hub_net" --gpus "$_gpus_flag" --restart no \
        --ipc=host -e HF_HUB_OFFLINE=1 \
        "${_port_args[@]}" "${_cuda_env[@]}" \
        -v "${_models_src}:/models" \
        "${_launch[@]}" \
        --model-path "/models/$MODEL_FILE" --served-model-name "$_model_name" \
        --host 0.0.0.0 --port "$ENGINE_PORT" \
        --context-length "$_ctx" \
        --mem-fraction-static "${SGL_MEM_FRACTION:-0.85}" \
        --kv-cache-dtype "${MODEL_KV_TYPE:-auto}" \
        "${_tp_args[@]}" "${_parser_args[@]}" "${_quant_args[@]}" "${_extra_args[@]}" > /dev/null
}
