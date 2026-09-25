#!/bin/bash
# ==============================================================================
# AI-CODER-WORKBENCH.SH | Workbench & Hub Engine Container Lifecycle
# run_workbench/exec_in_container for the per-project spoke container, and
# start_hub_engine (plus its GPU arg resolution and fast-storage model volume
# sync) for the shared Hub, the engine (re)start decision, and the post-start
# readiness poll. start_hub_engine is engine-neutral apart from the docker run
# itself: _run_llamacpp_engine here, _run_sglang_engine in ai-coder-sglang.sh.
# Building the images these run is ai-coder-image.sh.
# ==============================================================================

exec_in_container() {
    # Usage: exec_in_container [extra docker exec flags...] <container> <cmd> [args...]
    # Handles winpty on Git Bash automatically.
    # NOTE: do NOT pass -e PATH=... here. On Git Bash, MSYS converts the colon-
    # separated value into Windows-style paths through the winpty boundary, which
    # the Linux container cannot use. docker exec inherits the container's
    # image-set PATH (which already includes /usr/local/bin for npm globals) and
    # that is sufficient.
    # On Git Bash, MSYS converts /foo paths to Windows paths when winpty is the
    # intermediary, even with MSYS_NO_PATHCONV=1. The // prefix suppresses MSYS
    # conversion (treated as a UNC prefix); Linux normalises //foo → /foo. It
    # must cover the workdir AND every container-path argument the caller
    # passes (agent binaries, script paths, config files).
    local _wd="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wd="//$WORKSPACE_DIR"
    local cmd_args=(docker exec -it -w "$_wd" "$@")
    if [ "$IS_GITBASH" = "true" ]; then
        local _safe_args=() _a
        for _a in "${cmd_args[@]}"; do
            if [[ "$_a" == /* && ! "$_a" == //* ]]; then
                _a="//${_a#/}"
            fi
            _safe_args+=("$_a")
        done
        winpty "${_safe_args[@]}"
    else
        "${cmd_args[@]}"
    fi
}

run_workbench() {
    # Usage: run_workbench [extra docker run flags...] [-- <entrypoint-cmd>]
    # Starts the workbench with standard flags. Pass a custom entrypoint after --.
    echo -e "${ICON_GEAR} Mapping Spoke for [$PROJECT_ID]..."
    local extra_flags=()
    local entrypoint="mkdir -p \"/$WORKSPACE_DIR\"; trap 'true' EXIT; while true; do sleep 3600; done"
    local past_sep=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then past_sep=true; continue; fi
        if $past_sep; then entrypoint="$arg"; else extra_flags+=("$arg"); fi
    done
    local wb_network="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && wb_network="$HUB_ISOLATED_NET"
    local no_proxy_hosts="localhost,127.0.0.1,$GLOBAL_ENGINE_NAME"
    [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ] && no_proxy_hosts="$no_proxy_hosts,$GLOBAL_PROXY_NAME"
    # When isolated, don't inject proxy env vars — the container has no internet
    # access anyway, and proxy settings can interfere with internal container
    # communication if no_proxy isn't perfectly honoured by every client.
    local _wb_http_proxy="${DOWNLOAD_PROXY:-}"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _wb_http_proxy=""
    # On Git Bash, MSYS may still convert /$WORKSPACE_DIR to a Windows path for
    # --workdir even with MSYS_NO_PATHCONV=1. The // prefix suppresses conversion
    # and Linux containers normalise //foo → /foo.
    local _wb_workdir="/$WORKSPACE_DIR"
    [ "$IS_GITBASH" = "true" ] && _wb_workdir="//$WORKSPACE_DIR"
    # No --privileged: agents only need the workspace mount and network access,
    # and a privileged container would undermine the network-isolation option.
    # --stop-timeout 2: the keep-alive entrypoint ignores SIGTERM, so a short
    # grace period avoids a 10s docker stop hang on every exit.
    docker run -d --name "$WORKBENCH" --network "$wb_network" --stop-timeout 2 \
        -e "http_proxy=${_wb_http_proxy}" -e "https_proxy=${_wb_http_proxy}" \
        -e "HTTP_PROXY=${_wb_http_proxy}" -e "HTTPS_PROXY=${_wb_http_proxy}" \
        -e "no_proxy=$no_proxy_hosts" -e "NO_PROXY=$no_proxy_hosts" \
        -v "$(to_host_path "$(pwd)"):/$WORKSPACE_DIR" \
        -v "$(to_host_path "$HOME/.gitconfig-container"):/root/.gitconfig:ro" \
        --workdir "$_wb_workdir" \
        "${extra_flags[@]}" \
        "$IMAGE_NAME" /bin/bash -c "$entrypoint" > /dev/null
}

_resolve_engine_gpu_args() {
    # Sets _gpus_flag, _ts_args, _tp_args, _cuda_env for the caller based on
    # GPU_MODE. _ts_args is llama.cpp's --tensor-split, _tp_args SGLang's --tp
    # (see _resolve_sglang_tp_args); only the active engine's is ever set.
    # "single": exposes only GPU 0; also sets CUDA_VISIBLE_DEVICES to guard against
    # Docker Desktop / WSL2 passthrough quirks where --gpus device=0 isn't fully enforced.
    # "multi": exposes all GPUs and builds --tensor-split from per-GPU VRAM so llama.cpp
    # distributes compute (not just VRAM) across every card.
    _gpus_flag="all"
    _ts_args=()
    _tp_args=()
    _cuda_env=()
    if [ "${GPU_MODE:-multi}" = "single" ]; then
        _gpus_flag="device=0"
        _cuda_env=(-e CUDA_VISIBLE_DEVICES=0)
        echo -e "${ICON_GEAR} GPU Mode: ${YELLOW}Single (GPU 0 only)${NC}"
    elif engine_is_sglang; then
        _resolve_sglang_tp_args
    else
        # Split by FREE VRAM (fallback: capacity) so the display GPU — which
        # loses VRAM to the desktop — receives proportionally fewer layers.
        # This runs after the old engine is stopped, so free reflects reality.
        local _split_vals=()
        mapfile -t _split_vals < <(gpu_query_ints memory.free)
        if [ "${#_split_vals[@]}" -lt 2 ]; then
            mapfile -t _split_vals < <(gpu_query_ints memory.total)
        fi
        if [ "${#_split_vals[@]}" -gt 1 ]; then
            local _ts; _ts=$(IFS=,; echo "${_split_vals[*]}")
            _ts_args=(--tensor-split "$_ts")
            echo -e "${ICON_GEAR} GPU Mode: ${GREEN}Multi — distributing across ${#_split_vals[@]} GPUs (split: ${CYAN}${_ts}${NC}${GREEN})${NC}"
        fi
    fi
}

# Ensure the given models exist inside the fast-storage Docker volume.
# Usage: ensure_model_in_volume <model> [more-models...]
# Each <model> is a path relative to MODEL_STORAGE_DIR: a GGUF file
# (llama.cpp) or a Hugging Face snapshot directory (SGLang).
# On Windows hosts, bind mounts go through Docker Desktop's 9p bridge, making
# the engine's model load (every cold start) several times slower than the
# named volume, which lives on the Docker VM's native disk. The host copies in
# MODEL_STORAGE_DIR remain the download cache and source of truth; this copies
# them into the volume once per model (size-verified — a directory by the sum
# of its file sizes — and interruption-safe via a .part rename). Previously
# synced models are retained in the volume so switching family, tier or
# engine back is instant; remove the volume to reclaim disk.
# Runs its helper containers from $ENGINE_IMAGE (caller pulls it first), so
# an SGLang-only setup never pulls the llama.cpp image just for this.

# Shell snippet shared by the host and the helper containers: _msz <path>
# (_msz) prints a file's size, or the summed size of every file under a directory
# (directory entries' own sizes differ between filesystems, so du is avoided).
_MODEL_SZ_FN='_msz() { if [ -d "$1" ]; then find "$1" -type f -exec stat -c%s {} + 2>/dev/null | awk "{s+=\$1} END{print s+0}"; elif [ -f "$1" ]; then stat -c%s "$1"; else echo 0; fi; }'

ensure_model_in_volume() {
    local files=("$@") f
    [ "${#files[@]}" -gt 0 ] || return 1
    for f in "${files[@]}"; do
        [ -e "$MODEL_STORAGE_DIR/$f" ] || return 1
    done
    eval "$_MODEL_SZ_FN"

    docker volume create "$MODEL_VOLUME_NAME" >/dev/null 2>&1 || true

    # One container call lists current volume contents as "name size" lines:
    # every GGUF, plus every completed snapshot directory (marker present).
    # find (not a flat glob) so models nested under a family subfolder are
    # reported with their subfolder-relative path, matching $f below.
    local vol_listing
    vol_listing=$(docker run --rm --entrypoint /bin/sh -v "$MODEL_VOLUME_NAME:/vol" "$ENGINE_IMAGE" \
        -c "$_MODEL_SZ_FN"'
            find /vol -type f -name "*.gguf" 2>/dev/null | while read -r p; do printf "%s %s\n" "${p#/vol/}" "$(_msz "$p")"; done
            find /vol -type f -name "$1" 2>/dev/null | while read -r m; do d="${m%/*}"; printf "%s %s\n" "${d#/vol/}" "$(_msz "$d")"; done
            true' sh "$SGL_COMPLETE_MARKER" \
        2>/dev/null | tr -d '\r') || vol_listing=""

    local sync_files=() total_sz=0 host_sz vol_sz
    for f in "${files[@]}"; do
        host_sz=$(_msz "$MODEL_STORAGE_DIR/$f")
        [ "${host_sz:-0}" -gt 0 ] || return 1
        vol_sz=$(printf '%s\n' "$vol_listing" | awk -v n="$f" '$1==n{print $2}')
        if [ "${vol_sz:-0}" != "$host_sz" ]; then
            sync_files+=("$f")
            total_sz=$(( total_sz + host_sz ))
        fi
    done

    if [ "${#sync_files[@]}" -eq 0 ]; then
        # Nothing to copy — files no longer wanted (e.g. a draft model after
        # speculative decoding was turned off, or an old model) are left in
        # the volume rather than pruned.
        return 0
    fi

    echo -e "${ICON_GEAR} Syncing model(s) to fast storage volume ${DIM}(one-time per model)...${NC}"
    local _sync_name="ai-coder-model-sync"
    docker rm -f "$_sync_name" >/dev/null 2>&1 || true
    # Filenames are passed as positional args ("$@"), not interpolated into
    # the script text, so a filename with spaces/backticks/$() can't inject
    # shell commands into the container's sh -c.
    docker run -d --name "$_sync_name" --entrypoint /bin/sh \
        -v "$MODEL_VOLUME_NAME:/vol" \
        -v "$(to_host_path "$MODEL_STORAGE_DIR"):/src:ro" \
        "$ENGINE_IMAGE" -c '
            for f; do
                mkdir -p "/vol/$(dirname "$f")"
                rm -rf "/vol/$f.part" "/vol/$f"
                cp -r "/src/$f" "/vol/$f.part" && mv "/vol/$f.part" "/vol/$f" || exit 1
            done
        ' sh "${sync_files[@]}" >/dev/null || return 1

    local human_total; human_total=$(_human_size "$total_sz")
    while container_running "$_sync_name"; do
        local cur
        cur=$(docker exec "$_sync_name" /bin/sh -c "$_MODEL_SZ_FN"'
            tot=0
            for f; do
                if [ -e "/vol/$f" ]; then s=$(_msz "/vol/$f")
                else s=$(_msz "/vol/$f.part"); fi
                tot=$((tot+s))
            done
            echo $tot
        ' sh "${sync_files[@]}" 2>/dev/null | tr -d '\r') || cur=0
        case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
        printf "\r  Synced: %s / %s (%d%%)   " "$(_human_size "$cur")" "$human_total" "$(( cur * 100 / total_sz ))"
        sleep 3
    done
    printf "\r%-60s\r" ""

    local _rc; _rc=$(docker inspect -f '{{.State.ExitCode}}' "$_sync_name" 2>/dev/null | tr -d '\r') || _rc=1
    docker rm "$_sync_name" >/dev/null 2>&1 || true
    if [ "$_rc" != "0" ]; then
        echo -e "${YELLOW}⚠ Model volume sync failed (exit ${_rc}).${NC}"
        return 1
    fi
    echo -e "${ICON_OK} Model(s) cached in fast storage volume."
}

# Start the LiteLLM proxy container ($GLOBAL_PROXY_NAME) on the hub network,
# config written to ~/.ai-coder/litellm_config.yaml. Used by agents that need
# the proxy in front of the engine (set NEEDS_LITELLM_PROXY=true, e.g. Gemini).
_start_litellm_proxy() {
    local hub_net="$1"
    mkdir -p "$HOME/.ai-coder"
    local config_content; config_content=$(get_litellm_config)
    cat > "$HOME/.ai-coder/litellm_config.yaml" <<EOF
$config_content
EOF
    # on-failure:3 (not always) so a host reboot doesn't resurrect the proxy
    # orphaned without its engine. Port bound to localhost only. --port is
    # passed explicitly (LiteLLM's own image default also happens to be
    # 4000) so PROXY_PORT is a real single source of truth, not just a label
    # that would silently mismatch the container's actual listen port if ever
    # changed.
    docker run -d --name "$GLOBAL_PROXY_NAME" --network "$hub_net" -p "127.0.0.1:${PROXY_PORT}:${PROXY_PORT}" --restart on-failure:3 \
        -e "http_proxy=${DOWNLOAD_PROXY:-}" -e "https_proxy=${DOWNLOAD_PROXY:-}" \
        -e "no_proxy=localhost,127.0.0.1,$GLOBAL_ENGINE_NAME" \
        -v "$(to_host_path "$HOME/.ai-coder/litellm_config.yaml"):/app/config.yaml:ro" \
        "$LITELLM_IMAGE" --config /app/config.yaml --port "$PROXY_PORT" > /dev/null || {
        echo -e "${RED}✘ Failed to start proxy container${NC}"; return 1
    }
}

# llama.cpp docker run, called by start_hub_engine after the shared prelude
# has resolved _hub_net, _gpus_flag, _cuda_env, _ts_args, _port_args,
# _models_src and _draft_args (all in the caller's scope). Also sets
# LLAMA_SPEC_FLAGS, which start_hub_engine records in engine_spec state.
_run_llamacpp_engine() {
    # Speculative decoding strategy: initialize flags and map to llama.cpp args.
    # MTP uses built-in draft heads, ngram uses hashing, none disables it.
    LLAMA_SPEC_FLAGS=""
    case "${MODEL_SPEC_STRATEGY:-none}" in
        mtp)
            # Most MTP families (e.g. Qwen3.6 MTP) bake the draft heads into
            # the main GGUF itself — no MODEL_DRAFT_FILE, so the flags always
            # apply. Qwen3.8 instead pairs this with a real external draft file
            # (see qwen3.8.conf), which the spec_decode setting — or a failed
            # download, which clears MODEL_DRAFT_FILE — can make unavailable;
            # MODEL_DRAFT_DEFINED (captured before any such clearing, in
            # ai-coder) is what tells the two cases apart. Without this check,
            # a disabled/failed Qwen3.8 draft would still get --spec-type
            # draft-mtp with no draft model loaded to back it.
            # Self-contained MTP also needs the heads to actually be in the
            # GGUF — not every tier of an MTP family ships them (unsloth's
            # Gemma 4 GGUFs don't), and llama-server exits at load when they
            # are missing. An unreadable header keeps the family's choice.
            local _mtp_n=""
            if [ "${MODEL_DRAFT_DEFINED:-false}" != "true" ]; then
                _mtp_n=$(gguf_mtp_layers "$MODEL_STORAGE_DIR/$MODEL_FILE") || _mtp_n=""
            fi
            if [ "$_mtp_n" = "0" ]; then
                echo -e "${ICON_GEAR} Speculative decoding: ${DIM}disabled (model has no MTP layers)${NC}"
            elif [ "${MODEL_DRAFT_DEFINED:-false}" != "true" ] || spec_decode_enabled; then
                # MODEL_SPEC_DRAFT_N_MAX is per-family (default 3) — e.g.
                # qwen3.6MTP.conf's own verified value is 2; don't assume one
                # n-max fits every MTP model.
                LLAMA_SPEC_FLAGS="--spec-type draft-mtp --spec-draft-n-max ${MODEL_SPEC_DRAFT_N_MAX:-3}"
                MODEL_MAX_SLOTS="1" # CRITICAL: MTP does not support concurrent requests yet
                echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}MTP (built-in draft heads)${NC}"
                echo -e "${ICON_GEAR} MTP Override: ${YELLOW}Forcing --parallel 1${NC}"
            else
                echo -e "${ICON_GEAR} Speculative decoding: ${DIM}disabled (spec_decode setting off)${NC}"
            fi
            ;;
        ngram)
            LLAMA_SPEC_FLAGS="--spec-type ngram-mod --spec-default"
            echo -e "${ICON_GEAR} Speculative decoding: ${GREEN}ngram (hash-based)${NC}"
            ;;
        none|*)
            ;;
    esac

    local _jinja_args=()
    if [ "${MODEL_JINJA:-true}" = "true" ]; then
        _jinja_args=(--jinja)
        echo -e "${ICON_GEAR} Jinja template: ${GREEN}enabled${NC}"
    else
        echo -e "${ICON_GEAR} Jinja template: ${YELLOW}disabled (model uses non-JSON tool call format)${NC}"
    fi

    # Thinking mode: reasoning models (Qwen3) burn hundreds of tokens before
    # every tool call. MODEL_THINKING=false disables it for snappier turns.
    # With thinking on, --no-reasoning-preserve drops earlier turns' reasoning
    # from the prompt (templates like Qwen3.8's keep it by default), so it
    # stops eating context; MODEL_REASONING_PRESERVE=true keeps it.
    local _think_args=()
    if [ "${MODEL_THINKING:-true}" = "false" ]; then
        _think_args=(--reasoning-budget 0)
        echo -e "${ICON_GEAR} Thinking mode: ${YELLOW}disabled (--reasoning-budget 0)${NC}"
    elif [ "${MODEL_REASONING_PRESERVE:-false}" != "true" ] && \
         _llama_supports_flag "$ENGINE_IMAGE" --no-reasoning-preserve; then
        _think_args=(--no-reasoning-preserve)
        echo -e "${ICON_GEAR} Thinking mode: ${GREEN}enabled${NC} ${DIM}(past turns' reasoning dropped from context)${NC}"
    fi

    # Repeat penalty is off unless a family conf sets MODEL_REPEAT_PENALTY —
    # it penalizes legitimately repeated tokens (indentation, identifiers,
    # JSON keys in tool calls) and is a known cause of malformed tool calls.
    local _rp_args=()
    if [ -n "${MODEL_REPEAT_PENALTY:-}" ]; then
        _rp_args=(--repeat-penalty "$MODEL_REPEAT_PENALTY" --repeat-last-n "${MODEL_REPEAT_LAST_N:-128}")
        echo -e "${ICON_GEAR} Repeat penalty: ${YELLOW}${MODEL_REPEAT_PENALTY}${NC}"
    fi

    # --cache-reuse: agent conversations grow by appending, so reusing KV
    # cache chunks across requests avoids reprocessing the whole prompt each
    # turn — a large time-to-first-token win in agent loops.
    docker run -d --name "$GLOBAL_ENGINE_NAME" --network "$_hub_net" --gpus "$_gpus_flag" --restart no \
        "${_port_args[@]}" "${_cuda_env[@]}" \
        -v "${_models_src}:/models" \
        "$ENGINE_IMAGE" \
        -m "/models/$MODEL_FILE" --host 0.0.0.0 --port "$ENGINE_PORT" \
        --parallel "$MODEL_MAX_SLOTS" -ngl "${MODEL_NGL:-99}" -c "$MODEL_CTX_SIZE" --flash-attn on \
        -ctk "${MODEL_KV_TYPE:-q8_0}" -ctv "${MODEL_KV_TYPE_V:-${MODEL_KV_TYPE:-q8_0}}" \
        --batch-size "${MODEL_BATCH_SIZE:-1024}" --ubatch-size "${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}" --defrag-thold 0.1 \
        --cache-reuse "${MODEL_CACHE_REUSE:-256}" \
        ${LLAMA_SPEC_FLAGS} \
        "${_draft_args[@]}" "${_think_args[@]}" "${_rp_args[@]}" "${_jinja_args[@]}" "${_ts_args[@]}" > /dev/null
}

# Usage: _llama_supports_flag <image> <flag> — true when that image's
# llama-server --help lists <flag>. The stock image is pulled once and never
# refreshed, so an older one can predate a flag, and an unknown flag stops
# llama-server from starting at all. The --help run (a second or two) is
# cached in state.json per image ID and flag, so it happens once per image.
_llama_supports_flag() {
    local _img="$1" _flag="$2" _id _key _cached
    _id=$(docker image inspect -f '{{.Id}}' "$_img" 2>/dev/null | tr -d '\r') || return 1
    _key="llama_flag_${_flag//[^a-zA-Z0-9]/_}"
    _cached=$(read_pref "$STATE_FILE" "$_key" "")
    if [ "${_cached%%|*}" != "$_id" ]; then
        # Via a temp file, not a pipe: grep -q exiting early would fail the
        # docker run side under pipefail.
        local _res=no _tmp="${TMPDIR:-/tmp}/.ai-coder-llama-help.$$"
        MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /app/llama-server "$_img" --help > "$_tmp" 2>&1 || true
        grep -q -- "$_flag" "$_tmp" && _res=yes
        rm -f "$_tmp"
        _cached="$_id|$_res"
        write_pref "$STATE_FILE" "$_key" "$_cached"
    fi
    [ "${_cached##*|}" = "yes" ]
}

start_hub_engine() {
    echo -e "${ICON_GEAR} Initializing Global GPU Hub ($(engine_display_name))..."

    remove_containers "$GLOBAL_ENGINE_NAME"
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        remove_containers "$GLOBAL_PROXY_NAME"
    fi

    # The asymmetric-KV image is built locally at launch (before the hub
    # lock, see ensure_llama_asym_image) — there's no registry to pull it from.
    if [ "$ENGINE_IMAGE" = "$LLAMA_ASYM_IMAGE" ]; then
        docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1 || {
            echo -e "${RED}✘ Engine image ${ENGINE_IMAGE} is missing${NC}"; return 1; }
    else
        pull_image_if_missing "$ENGINE_IMAGE" || return 1
    fi
    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        pull_image_if_missing "$LITELLM_IMAGE" || return 1
    fi

    # External draft model: a small GGUF that proposes tokens the main
    # model verifies in one pass — typically 1.5-2x generation speed on code.
    # (Never under SGLang: spec_decode_enabled is false there.)
    local _draft_args=() _vol_files=("$MODEL_FILE")
    if spec_decode_enabled && [ -f "$MODEL_STORAGE_DIR/$MODEL_DRAFT_FILE" ]; then
        _draft_args=(--model-draft "/models/$MODEL_DRAFT_FILE" -ngld 99)
        _vol_files+=("$MODEL_DRAFT_FILE")
        echo -e "${ICON_GEAR} External draft model: ${GREEN}enabled${NC} ${DIM}(draft: ${MODEL_DRAFT_FILE})${NC}"
    fi

    # Model mount: fast Docker volume when enabled (with fallback to the
    # direct host folder mount if the sync fails for any reason).
    local _models_src; _models_src="$(to_host_path "$MODEL_STORAGE_DIR")"
    if [ "$(read_setting model_volume)" = "yes" ]; then
        if ensure_model_in_volume "${_vol_files[@]}"; then
            _models_src="$MODEL_VOLUME_NAME"
            echo -e "${ICON_GEAR} Model storage: ${GREEN}fast volume (${MODEL_VOLUME_NAME})${NC}"
        else
            echo -e "${YELLOW}⚠ Falling back to direct host folder mount for models.${NC}"
        fi
    fi

    local _gpus_flag _ts_args=() _tp_args=() _cuda_env=()
    _resolve_engine_gpu_args

    local _hub_net="$HUB_NETWORK"
    [ "${NETWORK_INTERNAL:-false}" = "true" ] && _hub_net="$HUB_ISOLATED_NET"

    local _port_args=()
    if [ "$(read_setting expose_host_port)" = "yes" ]; then
        # Bind to localhost only so the engine is not reachable from the LAN.
        _port_args=(-p "127.0.0.1:${ENGINE_PORT}:${ENGINE_PORT}")
        echo -e "${ICON_GEAR} Engine port: ${GREEN}published on localhost:${ENGINE_PORT}${NC}"
    fi

    # --restart no (NOT on-failure), for both engines: a restart policy
    # persists across Docker daemon restarts, so after a crash/BSOD mid-load
    # the engine would reload the model at full GPU power unattended as soon
    # as Docker Desktop came back — exactly the wrong behaviour on a machine
    # that just crashed (observed 2026-07-15: overnight re-crash after a GPU
    # hardware failure). A failed engine stays down until a human relaunches it.
    LLAMA_SPEC_FLAGS=""
    if engine_is_sglang; then
        _run_sglang_engine
    else
        _run_llamacpp_engine
    fi || {
        echo -e "${RED}✘ Failed to start engine container${NC}"; return 1
    }

    write_pref "$STATE_FILE" engine_backend "$ENGINE_BACKEND"
    write_pref "$STATE_FILE" engine_image "$ENGINE_IMAGE"
    write_pref "$STATE_FILE" engine_gpu_mode "${GPU_MODE:-multi}"
    write_pref "$STATE_FILE" engine_model "${MODEL_FILE:-}"
    # Informational only — deliberately NOT part of the restart-detection
    # comparison in ai-coder: with the engine running, detect_model budgets
    # from capacity instead of free VRAM, so the recomputed layer count can
    # differ by a few layers every launch and would restart-flap the engine.
    # A settings change that matters flips the selected model file instead,
    # which the engine_model comparison already catches.
    write_pref "$STATE_FILE" engine_ngl "${MODEL_NGL:-99}"
    write_pref "$STATE_FILE" engine_ctx "${MODEL_CTX_SIZE:-}"
    write_pref "$STATE_FILE" engine_kv "$(kv_type_label)"
    write_pref "$STATE_FILE" engine_batch "${MODEL_BATCH_SIZE:-1024}/${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}"
    write_pref "$STATE_FILE" engine_expose "$(read_setting expose_host_port)"
    write_pref "$STATE_FILE" engine_net "${NETWORK_INTERNAL:-false}"
    write_pref "$STATE_FILE" engine_mvol "$(read_setting model_volume)"
    write_pref "$STATE_FILE" engine_memfrac "$(_current_sgl_memfrac)"
    write_pref "$STATE_FILE" engine_thinking "$(_current_thinking)"
    local _spec_state="${MODEL_SPEC_STRATEGY:-none}"
    engine_is_sglang && _spec_state="none"
    [ "${#_draft_args[@]}" -gt 0 ] && _spec_state="external-draft"
    write_pref "$STATE_FILE" engine_spec "$_spec_state"

    # Informational, for the --status dashboard's size line: on-disk weights
    # (main model + draft), the estimated KV cache, and their estimated VRAM
    # total — weights scaled by the GPU share of layers under CPU offload.
    eval "$_MODEL_SZ_FN"
    local _f _w_bytes=0 _kv_bytes _vram_bytes
    for _f in "${_vol_files[@]}"; do
        _w_bytes=$(( _w_bytes + $(_msz "$MODEL_STORAGE_DIR/$_f") ))
    done
    _kv_bytes=$(_estimate_kv_bytes)
    _vram_bytes=$_w_bytes
    if [ "${MODEL_NGL:-99}" -lt 99 ] && [ "${MODEL_LAYERS:-0}" -gt 0 ] 2>/dev/null; then
        _vram_bytes=$(( _w_bytes * MODEL_NGL / MODEL_LAYERS ))
    fi
    write_pref "$STATE_FILE" engine_weights_bytes "$_w_bytes"
    write_pref "$STATE_FILE" engine_kv_bytes "$_kv_bytes"
    write_pref "$STATE_FILE" engine_vram_bytes "$(( _vram_bytes + _kv_bytes ))"
    # Filled in by record_engine_kv_measurement once the engine is up.
    write_pref "$STATE_FILE" engine_kv_measured_bytes ""
    write_pref "$STATE_FILE" engine_kv_pool_tokens ""
    ENGINE_STARTED_THIS_RUN=true

    start_gpu_guard

    if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
        _start_litellm_proxy "$_hub_net" || return 1
    fi
}

# SGLang's mem-fraction for the engine_memfrac restart check — "-" under
# llama.cpp, which has no such setting, so it never triggers a restart there.
_current_sgl_memfrac() {
    engine_is_sglang && echo "${SGL_MEM_FRACTION:-0.85}" || echo "-"
}

# Thinking mode for the engine_thinking restart check — "-" under SGLang,
# where it's a per-request option rather than an engine flag. "true+preserve"
# when thinking is on and past reasoning is kept (MODEL_REASONING_PRESERVE).
_current_thinking() {
    if engine_is_sglang; then echo "-"; return; fi
    local _t="${MODEL_THINKING:-true}"
    [ "$_t" != "false" ] && [ "${MODEL_REASONING_PRESERVE:-false}" = "true" ] && _t="$_t+preserve"
    echo "$_t"
}

# Sets WORKBENCH_STARTED_BY_US so the caller's cleanup only stops containers
# this session actually started (not one shared with a concurrent session).
# The check-then-start is guarded by a mkdir lock (atomic on both WSL and Git
# Bash) so two sessions launched close together in the same project+tool
# can't both decide they "started" the container and race to stop it on exit.
ensure_workbench_running() {
    WORKBENCH_STARTED_BY_US=false
    local _lock_dir="${TMPDIR:-/tmp}/.ai-coder-wb-lock-${WORKBENCH}"
    acquire_lock "$_lock_dir" 0.2 150

    local _rc=0
    if container_running "$WORKBENCH"; then
        :
    else
        WORKBENCH_STARTED_BY_US=true
        # Always recreate rather than `docker start` a stopped container: every
        # bind mount/env var the workbench needs comes from start_workbench's
        # docker run flags, and a stopped container only has whatever flags were
        # current when it was first created. A stale container from before an
        # agent script added a new mount would silently launch without it.
        # Nothing of value lives in the container's own writable layer — the
        # workspace, npm cache, and every tool's config dir are all host-mounted
        # — so recreating a stopped container is safe and cheap (its entrypoint
        # is just a sleep loop).
        if [ -n "$(docker ps -aq -f name=^/${WORKBENCH}$ 2>/dev/null)" ]; then
            docker rm "$WORKBENCH" >/dev/null 2>&1 || true
        fi
        start_workbench || _rc=1
    fi

    release_lock "$_lock_dir"
    return $_rc
}
# Decide whether the running Hub engine (if any) matches the current
# settings, and (re)start it when it does not — or when the LiteLLM proxy
# is missing. Must be called while the caller holds the hub-start lock
# (GLOBAL_ENGINE_NAME is a machine-wide singleton).
ensure_engine_currently_running() {
    _engine_running=false
    container_running "$GLOBAL_ENGINE_NAME" && _engine_running=true
    _need_engine_restart=false

    if $_engine_running; then
        # Restart if any engine-affecting setting changed since it was last
        # started. Each entry is "label|saved-state-value|current-value"; a
        # mismatch with a non-empty saved value (i.e. the engine actually
        # recorded one last start — absent on a first run) triggers a restart.
        # All entries are checked (not just the first mismatch), so one restart
        # reports every setting that actually changed. Add a new engine-affecting
        # setting by appending a line here rather than a whole branch.
        _cur_spec=no
        spec_decode_enabled && [ -f "$MODEL_STORAGE_DIR/${MODEL_DRAFT_FILE:-}" ] && _cur_spec=yes
        _restart_checks=(
            "Engine|$(read_pref "$STATE_FILE" engine_backend "")|${ENGINE_BACKEND:-llamacpp}"
            "Engine image|$(read_pref "$STATE_FILE" engine_image "")|${ENGINE_IMAGE}"
            "SGLang memory fraction|$(read_pref "$STATE_FILE" engine_memfrac "")|$(_current_sgl_memfrac)"
            "GPU mode|$(read_pref "$STATE_FILE" engine_gpu_mode "")|${GPU_MODE:-multi}"
            "Model|$(read_pref "$STATE_FILE" engine_model "")|${MODEL_FILE:-}"
            "Context size|$(read_pref "$STATE_FILE" engine_ctx "")|${MODEL_CTX_SIZE:-}"
            "KV cache type|$(read_pref "$STATE_FILE" engine_kv "")|$(kv_type_label)"
            "Batch size|$(read_pref "$STATE_FILE" engine_batch "")|${MODEL_BATCH_SIZE:-1024}/${MODEL_UBATCH_SIZE:-${MODEL_BATCH_SIZE:-1024}}"
            "Host port exposure|$(read_pref "$STATE_FILE" engine_expose "")|$(read_setting expose_host_port)"
            "Network isolation|$(read_pref "$STATE_FILE" engine_net "")|${NETWORK_INTERNAL:-false}"
            "Model storage mode|$(read_pref "$STATE_FILE" engine_mvol "")|$(read_setting model_volume)"
            "Speculative decoding|$(read_pref "$STATE_FILE" engine_spec "")|$_cur_spec"
            "Thinking mode|$(read_pref "$STATE_FILE" engine_thinking "")|$(_current_thinking)"
        )
        for _check in "${_restart_checks[@]}"; do
            IFS='|' read -r _label _old _new <<< "$_check"
            if [ -n "$_old" ] && [ "$_old" != "$_new" ]; then
                echo -e "${YELLOW}◈ ${_label} changed (${_old} → ${_new}) — restarting engine...${NC}"
                _need_engine_restart=true
            fi
        done
    fi

    if ! $_engine_running || $_need_engine_restart; then
        docker rm "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        start_hub_engine || { echo -e "${RED}✘ Hub startup failed${NC}"; exit 1; }
    elif [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ] && \
         ! container_running "$GLOBAL_PROXY_NAME"; then
        # Engine is already up but proxy is missing (e.g. switched from a non-proxy
        # agent). Restart both so the proxy gets a clean start alongside the engine.
        docker rm "$GLOBAL_ENGINE_NAME" "$GLOBAL_PROXY_NAME" 2>/dev/null || true
        start_hub_engine || { echo -e "${RED}✘ Hub startup failed${NC}"; exit 1; }
    fi
}

# GET <url> from inside the engine container (2s timeout), printing the body.
# llama.cpp's image ships curl; SGLang's is only guaranteed to have Python,
# so it uses urllib there. Errors print nothing, which callers treat as down.
engine_http_get() {
    if engine_is_sglang; then
        docker exec "$GLOBAL_ENGINE_NAME" python3 -c '
import sys, urllib.request
try:
    sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=2).read().decode())
except Exception:
    pass' "$1" 2>/dev/null
    else
        docker exec "$GLOBAL_ENGINE_NAME" curl -s -m 2 "$1" 2>/dev/null
    fi
}

# Wait until the engine (and the LiteLLM proxy, when in use) answers its
# readiness probes, printing progress as it polls; on success runs the VRAM
# oversubscription check, on timeout prints engine log diagnostics.
wait_for_engine_ready() {
    echo -ne "${CYAN}◈ Syncing VRAM Slots:${NC} "
    retry_count=0
    max_retries=300
    # SGLang's first start JIT-compiles kernels and captures CUDA graphs
    # before serving, which can take several minutes on its own.
    engine_is_sglang && max_retries=900
    engine_ready=false
    proxy_ready=false

    while [ "$retry_count" -lt "$max_retries" ]; do
        # Bail early if the engine container has stopped (e.g. unsupported flag, missing model).
        # The engine runs with --restart no, so any exit means it won't come back.
        if ! container_running "$GLOBAL_ENGINE_NAME"; then
            break
        fi
        # Reset every iteration: a probe that succeeded on an earlier loop but then
        # fails on a later one (transient hiccup, container still settling) must
        # not leave a stale "ready" from before make the loop declare success.
        engine_ready=false
        proxy_ready=false
        # Fire both checks in parallel to avoid waiting serially
        engine_http_get "http://localhost:${ENGINE_PORT}/v1/models" | grep -q '"id"' &
        _engine_pid=$!

        if [ "${NEEDS_LITELLM_PROXY:-false}" = "true" ]; then
            # Probe the proxy from inside the Docker network (via the engine
            # container) — on the isolated internal network the proxy's published
            # port is not reachable from the host, so a host-side curl would
            # never succeed.
            engine_http_get "http://$GLOBAL_PROXY_NAME:${PROXY_PORT}/v1/models" | grep -q '"object"' &
            _proxy_pid=$!
            wait "$_engine_pid" && engine_ready=true
            wait "$_proxy_pid"  && proxy_ready=true
        else
            wait "$_engine_pid" && engine_ready=true
            proxy_ready=true
        fi

        if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then break; fi
        retry_count=$((retry_count + 1))
        echo -ne "◈"
        sleep 1
    done

    if [ "$engine_ready" = "true" ] && [ "$proxy_ready" = "true" ]; then
        echo -e " ${GREEN}READY${NC}"
        # The engine can report ready while a GPU is silently oversubscribed
        # (WDDM pages the overflow to system RAM) — check and warn before use.
        warn_if_vram_oversubscribed
        record_engine_kv_measurement
    else
        echo -e " ${RED}TIMEOUT${NC}"
        echo -e "${RED}✘ Engine/Proxy failed to initialize after ~${retry_count} seconds${NC}"
        # Basic diagnostics
        _cid=$(docker ps -aq -f "name=$GLOBAL_ENGINE_NAME" 2>/dev/null) || true
        if [ -n "${_cid:-}" ]; then
            docker logs "$GLOBAL_ENGINE_NAME" 2>&1 | tail -20 | sed 's/^/    /'
        fi
        exit 1
    fi
}

# After a fresh engine start, check the KV cache the engine actually set up
# (from its startup log) against the estimate the tier was picked with.
# llama.cpp: sums every KV and recurrent-state cache size line (a
# sliding-window model logs one per cache), stopping at the draft model's,
# records it for the --status dashboard (engine_kv_measured_bytes), and warns
# when it exceeds the estimate by more than 10% — that tier's MODEL_N_KV is
# missing or wrong, so the tier choice may overfill VRAM; --kv-probe fixes it.
# SGLang: it sizes its KV pool to whatever VRAM is left rather than to the
# context, so the check is whether that pool (max_total_num_tokens) holds one
# full-length context (context_len); warns when it doesn't.
record_engine_kv_measurement() {
    [ "${ENGINE_STARTED_THIS_RUN:-false}" = "true" ] || return 0
    # Via a temp file, not a pipe: awk exiting early would fail docker logs
    # under pipefail.
    local _tmp="${TMPDIR:-/tmp}/.ai-coder-kvlog.$$" _bytes _est _pool _ctx
    docker logs "$GLOBAL_ENGINE_NAME" > "$_tmp" 2>&1 || true
    if engine_is_sglang; then
        read -r _pool _ctx <<< "$(awk '
            match($0, /max_total_num_tokens=[0-9]+/) {
                p = substr($0, RSTART + 21, RLENGTH - 21)
                if (match($0, /context_len=[0-9]+/)) c = substr($0, RSTART + 12, RLENGTH - 12)
            }
            END { if (p != "") print p, c }' "$_tmp" 2>/dev/null | tr -d '\r')" || true
        rm -f "$_tmp"
        case "${_pool:-}${_ctx:-}" in ''|*[!0-9]*) return 0 ;; esac
        write_pref "$STATE_FILE" engine_kv_pool_tokens "$_pool"
        if [ "$_pool" -lt "$_ctx" ]; then
            echo -e "${YELLOW}⚠ KV cache: SGLang's pool holds ${_pool} tokens, less than the ${_ctx}-token context — longer conversations will fail.${NC}"
            echo -e "${DIM}  Lower the context level or pick a smaller tier ($(basename "$0") --model), or re-check this family: $(basename "$0") --kv-probe ${FAMILY_PREF:-<family>}${NC}"
        fi
        return 0
    fi
    _bytes=$(awk '
        /loading draft model/ { exit }
        /llama_(kv_cache[a-z_]*|memory_recurrent): +size = +[0-9.]+ MiB/ {
            if (match($0, /size = +[0-9.]+/)) {
                s = substr($0, RSTART, RLENGTH); sub(/size = +/, "", s); t += s
            }
        }
        END { if (t > 0) printf "%.0f", t * 1048576 }' "$_tmp" 2>/dev/null | tr -d '\r') || true
    rm -f "$_tmp"
    [ -n "$_bytes" ] || return 0
    write_pref "$STATE_FILE" engine_kv_measured_bytes "$_bytes"
    _est=$(read_pref "$STATE_FILE" engine_kv_bytes "0")
    case "$_est" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_bytes" -gt $(( _est + _est / 10 )) ]; then
        echo -e "${YELLOW}⚠ KV cache: llama.cpp allocated $(_human_size "$_bytes"), but the tier was picked assuming $(_human_size "$_est") — it may not fit VRAM.${NC}"
        echo -e "${DIM}  Record this family's real KV sizes: $(basename "$0") --kv-probe ${FAMILY_PREF:-<family>} --write${NC}"
    fi
}
