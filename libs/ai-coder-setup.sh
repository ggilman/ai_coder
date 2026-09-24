#!/bin/bash
# ==============================================================================
# AI-CODER | Setup Wizard
# The --setup wizard: setup_toggle_pref plus one setup_step_* per question,
# called in sequence from cmd_setup. The model-sizing steps — setup_step_ctx,
# setup_step_kv / setup_step_sgl_kv, setup_step_vram_overhead,
# setup_step_cpu_offload and setup_step_sgl_mem_fraction — are called from
# the --model flow in ai-coder instead (model-affecting choices are
# re-prompted there rather than living in the wizard). Steps that only apply to one inference engine are skipped by
# cmd_setup for the other (see setup_step_engine).
# ==============================================================================

# gum bootstrap/resolution (ensure_gum, resolve_gum_cmd, _download_gum_binary)
# — used by cmd_setup below (and _menu_ui_init in ai-coder-menus.sh).
# ai-status.sh and offline/bundle.sh source ai-coder-gum.sh directly;
# it's self-contained (see that file's header).
source "$(dirname "${BASH_SOURCE[0]}")/ai-coder-gum.sh"

# Prompts a yes/no setup question, writes the pref, and prints a status message.
# Shared by every setup_step_* that is a plain on/off toggle.
# Usage: setup_toggle_pref <pref_key> <title> <question> <detail> <prompt> \
#            <cur_display> <cur_yesno> <yes_msg> <no_msg> [<yes_value>] [<no_value>]
# <cur_display> is what the "unchanged" message shows; <cur_yesno> is what
# ui_yesno pre-selects — normally the same value, but callers whose pref
# stores something other than yes/no (e.g. gpu_mode: multi/single) pass the
# raw value as <cur_display> and its yes/no-mapped equivalent as <cur_yesno>.
# <yes_value>/<no_value> default to "yes"/"no" — override for those same callers.
setup_toggle_pref() {
    local key="$1" title="$2" question="$3" detail="$4" prompt="$5"
    local cur_display="$6" cur_yesno="$7" yes_msg="$8" no_msg="$9"
    local yes_value="${10:-yes}" no_value="${11:-no}"
    local input; input=$(ui_yesno "$title" "$question" "$detail" "$prompt" "$cur_display" "$cur_yesno")
    case "$input" in
        yes)
            write_pref "$SETTINGS_FILE" "$key" "$yes_value"
            echo -e "$yes_msg"
            ;;
        no)
            write_pref "$SETTINGS_FILE" "$key" "$no_value"
            echo -e "$no_msg"
            ;;
        *)
            printf "%s  %s unchanged (%s)%s\n" "$DIM" "$title" "$cur_display" "$NC"
            ;;
    esac
}

setup_step_alias() {
    # Pick the rc file by shell: .bash_profile under Git Bash, .zshrc when the
    # active shell is zsh ($SHELL ends in "zsh"), .bashrc otherwise.
    local rc_file="$HOME/.bashrc"
    if [ "$IS_GITBASH" = "true" ]; then
        rc_file="$HOME/.bash_profile"
    elif [ "$SHELL" != "${SHELL%zsh}" ]; then
        rc_file="$HOME/.zshrc"
    fi

    local _alias_exists=false
    grep -q "alias $ALIAS_NAME=" "$rc_file" 2>/dev/null && _alias_exists=true
    local _alias_input; _alias_input=$(ui_yesno "Shell alias" \
        "Shell alias — '${ALIAS_NAME}' shortcut in $rc_file" \
        "Skip if you prefer to add ai-coder to your PATH manually." \
        "Add alias? [y/n, Enter to keep]:" \
        "$([ "$_alias_exists" = "true" ] && echo "set" || echo "not set")" \
        "$([ "$_alias_exists" = "true" ] && echo "yes" || echo "no")")
    case "$_alias_input" in
        yes)
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo "alias $ALIAS_NAME='\"$(realpath "$0")\"'" >> "$rc_file"
            echo -e "${ICON_OK} Alias '${ALIAS_NAME}' added to $rc_file. Run: ${CYAN}source $rc_file${NC}"
            ;;
        no)
            touch "$rc_file"
            sed -i.bak "/alias $ALIAS_NAME=/d" "$rc_file"
            echo -e "${DIM}  Alias removed from $rc_file.${NC}"
            ;;
        *)
            echo -e "${DIM}  Alias unchanged.${NC}"
            ;;
    esac
}

setup_step_proxy() {
    local _cur_proxy; _cur_proxy=$(read_setting proxy)
    local _proxy_input; _proxy_input=$(ui_input "Proxy" \
        "Proxy configuration:" \
        "Enter a URL to set, '-' to clear, or leave blank to keep." \
        "Proxy URL:" \
        "${_cur_proxy:-none}" \
        "$_cur_proxy")
    case "$_proxy_input" in
        "")
            echo -e "${DIM}  Proxy unchanged.${NC}"
            ;;
        -)
            write_pref "$SETTINGS_FILE" proxy ""
            echo -e "${DIM}  Proxy cleared.${NC}"
            ;;
        *)
            write_pref "$SETTINGS_FILE" proxy "$_proxy_input"
            printf "%s  Proxy saved: %s%s%s\n" "${ICON_OK}" "${CYAN}" "$_proxy_input" "${NC}"
            ;;
    esac
}

setup_step_network() {
    local _cur_iso; _cur_iso=$(read_setting isolated)
    setup_toggle_pref isolated "Network isolation" \
        "Network isolation — block all internet access from containers?" \
        "(Recommended for regulated environments. Leave blank to keep current setting.)" \
        "Isolate containers? [y/N]:" \
        "$_cur_iso" "$_cur_iso" \
        "${ICON_OK} Network isolation ${GREEN}enabled${NC}." \
        "${DIM}  Network isolation disabled.${NC}"
}

# Inference engine behind the Hub. Changing it clears the saved model family
# (state.json family_pref) so the next launch re-shows the family menu,
# filtered to what the new engine can run — SGLang only lists families that
# define MODEL_SGL_* candidates. Updates ENGINE_BACKEND/ENGINE_IMAGE in place
# so the rest of this wizard shows the new engine's questions.
setup_step_engine() {
    local _cur_engine; _cur_engine=$(read_setting engine)
    local _engine_input; _engine_input=$(ui_menu "Inference engine" \
        "Inference engine — which server should run the local model?" \
        "llama.cpp (default): GGUF models, every model family, CPU offload and
speculative decoding. SGLang: Hugging Face (AWQ/GPTQ/FP8) models with a
faster serving path, but only for families that define SGLang models, and
its Docker image is ~15GB (pulled on first launch)." \
        "Engine [${_cur_engine}]:" \
        "$_cur_engine" \
        "llamacpp" "llama.cpp — GGUF, all families (default)" \
        "sglang"   "SGLang — Hugging Face models, selected families")
    case "$_engine_input" in
        llamacpp|sglang)
            write_pref "$SETTINGS_FILE" engine "$_engine_input"
            if [ "$_engine_input" != "$_cur_engine" ]; then
                write_pref "$STATE_FILE" family_pref ""
                echo -e "${ICON_OK} Engine set to ${GREEN}${_engine_input}${NC} — you'll pick a model family on next launch."
            else
                printf "%s  Engine unchanged (%s)%s\n" "$DIM" "$_cur_engine" "$NC"
            fi
            ;;
        "")
            printf "%s  Engine unchanged (%s)%s\n" "$DIM" "$_cur_engine" "$NC"
            ;;
        *)
            printf "%s⚠ Unknown engine '%s' — keeping %s%s\n" "$YELLOW" "$_engine_input" "$_cur_engine" "$NC"
            ;;
    esac
    if [ -n "${ENGINE_BACKEND_ENV:-}" ]; then
        echo -e "${YELLOW}  Note: ENGINE_BACKEND=${ENGINE_BACKEND_ENV} is exported in your environment and overrides this setting.${NC}"
    fi
    ENGINE_BACKEND="${ENGINE_BACKEND_ENV:-}"
    ensure_engine_config
}

# SGLang only (asked in --model): share of each GPU's VRAM SGLang
# pre-allocates up front for the model weights plus its KV-cache pool — its
# counterpart of llama.cpp's VRAM overhead reserve (the share it leaves
# unallocated is its overhead allowance).
setup_step_sgl_mem_fraction() {
    local _cur_frac; _cur_frac=$(read_setting sgl_mem_fraction)
    local _frac_input; _frac_input=$(ui_input "SGLang memory fraction" \
        "SGLang memory fraction — share of each GPU's VRAM to pre-allocate for model + KV cache?" \
        "Recommended: 0.85. SGLang claims this share of total VRAM at start-up.
Lower it (e.g. 0.75) if the GPU also drives your display or you see
out-of-memory errors; range 0.50-0.95." \
        "Fraction [${_cur_frac}]:" \
        "$_cur_frac" \
        "$_cur_frac")
    case "$_frac_input" in
        "")
            printf "%s  SGLang memory fraction unchanged (%s)%s\n" "$DIM" "$_cur_frac" "$NC"
            ;;
        0.[5-8][0-9]|0.9[0-5]|0.[5-9])
            write_pref "$SETTINGS_FILE" sgl_mem_fraction "$_frac_input"
            echo -e "${ICON_OK} SGLang memory fraction set to ${GREEN}${_frac_input}${NC}."
            ;;
        *)
            printf "%s⚠ Out of range (0.50-0.95) — keeping %s%s\n" "$YELLOW" "$_cur_frac" "$NC"
            ;;
    esac
}

# GPU mode — only prompt if multiple GPUs are detected
setup_step_gpu() {
    local _gpu_count; _gpu_count=$($SMI --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | grep -c '.' || echo 1)
    [ "${_gpu_count:-1}" -gt 1 ] || return 0

    local _cur_gpu; _cur_gpu=$(read_setting gpu_mode)
    local _cur_gpu_yesno; _cur_gpu_yesno=$([ "$_cur_gpu" = "multi" ] && echo "yes" || echo "no")
    setup_toggle_pref gpu_mode "GPU mode" \
        "GPU mode — ${_gpu_count} GPUs detected. Use all for inference?" \
        "" \
        "Use all GPUs? [Y/n]:" \
        "$_cur_gpu" "$_cur_gpu_yesno" \
        "${ICON_OK} GPU mode set to ${GREEN}multi${NC}." \
        "${DIM}  GPU mode set to single.${NC}" \
        multi single
}

setup_step_ctx() {
    local _cur_ctx; _cur_ctx=$(read_setting ctx_level)
    local _ctx_input; _ctx_input=$(ui_menu "Context window" \
        "Context window level — how many tokens of context should the model keep?" \
        "4k / 8k / 16k / 32k / 64k (default) / 128k / 256k
Larger = more context, but higher VRAM usage and slower responses." \
        "Context level [${_cur_ctx}]:" \
        "$_cur_ctx" \
        "4k"   "Smallest — minimal VRAM usage" \
        "8k"   "Small tasks" \
        "16k"  "Light coding sessions" \
        "32k"  "Medium projects" \
        "64k"  "Default — balanced" \
        "128k" "Large codebases" \
        "256k" "Largest — highest VRAM usage, slowest")
    case "${_ctx_input}" in
        4k|8k|16k|32k|64k|128k|256k)
            write_pref "$SETTINGS_FILE" ctx_level "$_ctx_input"
            printf "%s%s Context level set to %s%s%s\n" "${ICON_OK}" "" "${GREEN}" "$_ctx_input" "${NC}."
            ;;
        "")
            printf "%s  Context level unchanged (%s)%s\n" "$DIM" "$_cur_ctx" "$NC"
            ;;
        *)
            printf "%s⚠ Unknown level '%s' — keeping %s%s\n" "$YELLOW" "$_ctx_input" "$_cur_ctx" "$NC"
            ;;
    esac
}

# llama.cpp KV cache quantization (kv_mode, resolved by ensure_kv_config).
setup_step_kv() {
    local _cur_kv; _cur_kv=$(read_setting kv_mode)
    local _kv_input; _kv_input=$(ui_menu "KV cache" \
        "KV cache quantization — how compactly should the model's context be stored?" \
        "Smaller KV cache = less VRAM, which can unlock a bigger model tier or a
larger context, at some cost to long-context recall. Keys are more
quantization-sensitive than values, so the asymmetric option keeps keys at
q8_0. It needs a llama.cpp kernel the stock image doesn't ship, so the first
launch builds llama.cpp locally (one time, ~10-30 min)." \
        "KV cache [${_cur_kv}]:" \
        "$_cur_kv" \
        "default" "Full q8_0/q8_0 — best quality (family default)" \
        "asym"    "Asymmetric q8_0 K / q4_0 V — ~25% less KV VRAM, near-q8 quality" \
        "q4"      "q4_0/q4_0 — ~50% less KV VRAM, noticeable long-context loss")
    case "$_kv_input" in
        default)
            write_pref "$SETTINGS_FILE" kv_mode default
            echo -e "${ICON_OK} KV cache set to the family default (usually ${GREEN}q8_0/q8_0${NC}) — applied on next engine start."
            ;;
        asym)
            write_pref "$SETTINGS_FILE" kv_mode asym
            echo -e "${ICON_OK} KV cache set to ${GREEN}q8_0 K / q4_0 V${NC} — applied on next engine start."
            docker image inspect "$LLAMA_ASYM_IMAGE" >/dev/null 2>&1 || \
                echo -e "${YELLOW}  The next launch builds llama.cpp locally first (one time, ~10-30 min).${NC}"
            ;;
        q4)
            write_pref "$SETTINGS_FILE" kv_mode q4
            echo -e "${ICON_OK} KV cache set to ${GREEN}q4_0/q4_0${NC} — applied on next engine start."
            ;;
        "")
            printf "%s  KV cache unchanged (%s)%s\n" "$DIM" "$_cur_kv" "$NC"
            ;;
        *)
            printf "%s⚠ Unknown option '%s' — keeping %s%s\n" "$YELLOW" "$_kv_input" "$_cur_kv" "$NC"
            ;;
    esac
}

# SGLang counterpart of setup_step_kv (called from the --model flow):
# SGLang has no q4 KV cache, but can store it as FP8 instead of the model's
# 16-bit dtype, halving the KV pool per token.
setup_step_sgl_kv() {
    local _cur_fp8; _cur_fp8=$(read_setting sgl_kv_fp8)
    setup_toggle_pref sgl_kv_fp8 "FP8 KV cache" \
        "FP8 KV cache — store SGLang's KV cache as fp8_e4m3?" \
        "Halves KV-cache VRAM vs the model's own 16-bit dtype, which can unlock
a bigger model tier or larger context. Small quality cost on long-context
recall." \
        "Enable FP8 KV cache? [y/N]:" \
        "$_cur_fp8" "$_cur_fp8" \
        "${ICON_OK} FP8 KV cache ${GREEN}enabled${NC} — applied on next engine start." \
        "${DIM}  FP8 KV cache disabled — using the model's own dtype.${NC}"
}

setup_step_vram_overhead() {
    local _cur_vram_oh; _cur_vram_oh=$(read_setting vram_overhead)
    local _vram_oh_input; _vram_oh_input=$(ui_input "VRAM overhead" \
        "VRAM overhead reserve — how many GB of VRAM should be reserved for CUDA/system overhead?" \
        "Recommended: 1GB. Larger values can prevent OOMs on high-load GPUs." \
        "Reserve (GB) [${_cur_vram_oh}]:" \
        "$_cur_vram_oh" \
        "$_cur_vram_oh")
    case "${_vram_oh_input}" in
        *[!0-9]*)
            printf "%s⚠ Not a number — keeping %s%s\n" "$YELLOW" "$_cur_vram_oh" "$NC"
            ;;
        "")
            printf "%s  VRAM overhead unchanged (%s)%s\n" "$DIM" "$_cur_vram_oh" "$NC"
            ;;
        *)
            write_pref "$SETTINGS_FILE" vram_overhead "$_vram_oh_input"
            echo -e "${ICON_OK} VRAM overhead reserve set to ${GREEN}${_vram_oh_input}GB${NC}."
            ;;
    esac
}

setup_step_cpu_offload() {
    local _cur_offload; _cur_offload=$(read_setting cpu_offload_pct)
    local _offload_input; _offload_input=$(ui_input "CPU offload" \
        "CPU offload threshold — run a bigger model with a few layers on CPU when at least this % of it fits in VRAM?" \
        "Recommended: 90 — worst case is roughly half generation speed. Range
50-99; 0 keeps only models that fit fully on the GPU. Never applies to a
higher quant of the same model, only to a genuinely bigger one." \
        "Threshold in % (0 disables) [${_cur_offload}]:" \
        "$_cur_offload" \
        "$_cur_offload")
    case "${_offload_input}" in
        *[!0-9]*)
            printf "%s⚠ Not a number — keeping %s%s\n" "$YELLOW" "$_cur_offload" "$NC"
            ;;
        "")
            printf "%s  CPU offload threshold unchanged (%s)%s\n" "$DIM" "$_cur_offload" "$NC"
            ;;
        0)
            write_pref "$SETTINGS_FILE" cpu_offload_pct 0
            echo -e "${ICON_OK} CPU offload ${YELLOW}disabled${NC} — only fully GPU-resident models will be selected."
            ;;
        *)
            if [ "$_offload_input" -ge 50 ] && [ "$_offload_input" -le 99 ]; then
                write_pref "$SETTINGS_FILE" cpu_offload_pct "$_offload_input"
                echo -e "${ICON_OK} CPU offload threshold set to ${GREEN}${_offload_input}%${NC}."
            else
                printf "%s⚠ Out of range (50-99, or 0 to disable) — keeping %s%s\n" "$YELLOW" "$_cur_offload" "$NC"
            fi
            ;;
    esac
}

setup_step_mcp_extras() {
    local _cur_extras; _cur_extras=$(read_setting mcp_extras)
    setup_toggle_pref mcp_extras "MCP extras" \
        "MCP extras — register the optional MCP servers with each agent?" \
        "Extras: memory, sequential-thinking, conan, context7, brave-search, github, fetch, time.
Every registered server adds tool definitions to the model's context on every
request — small local models get slower and worse at tool selection as the
list grows. Core servers (filesystem, git, shell) are always registered." \
        "Enable MCP extras? [y/N]:" \
        "$_cur_extras" "$_cur_extras" \
        "${ICON_OK} MCP extras ${GREEN}enabled${NC} — applied on next launch (no rebuild needed)." \
        "${DIM}  MCP extras disabled — only core servers are registered.${NC}"
}

setup_step_keep_hub() {
    local _cur_keep; _cur_keep=$(read_setting keep_hub)
    local _keep_input; _keep_input=$(ui_yesno "Keep hub warm" \
        "Keep hub warm — leave the engine running after the last session exits?" \
        "Skips the model load on your next launch. Uses GPU VRAM while idle;
stop it any time with: ai --clean" \
        "Keep hub warm? [y/N]:" \
        "$_cur_keep" "$_cur_keep")
    case "$_keep_input" in
        yes)
            write_pref "$SETTINGS_FILE" keep_hub yes
            echo -e "${ICON_OK} Hub will ${GREEN}stay warm${NC} after sessions end."
            local _cur_timeout; _cur_timeout=$(read_setting keep_hub_timeout)
            local _timeout_input; _timeout_input=$(ui_input "Idle timeout" \
                "" \
                "" \
                "Auto-stop after how many idle minutes? [${_cur_timeout}] (0 = keep forever):" \
                "" \
                "$_cur_timeout")
            case "$_timeout_input" in
                "")
                    printf "%s  Idle timeout unchanged (%s min)%s\n" "$DIM" "$_cur_timeout" "$NC"
                    ;;
                *[!0-9]*)
                    printf "%s⚠ Not a number — keeping %s min%s\n" "$YELLOW" "$_cur_timeout" "$NC"
                    ;;
                *)
                    write_pref "$SETTINGS_FILE" keep_hub_timeout "$_timeout_input"
                    if [ "$_timeout_input" = "0" ]; then
                        echo -e "${DIM}  Hub will stay warm until stopped with --clean.${NC}"
                    else
                        echo -e "${ICON_OK} Hub auto-stops after ${GREEN}${_timeout_input}${NC} idle minutes."
                    fi
                    ;;
            esac
            ;;
        no)
            write_pref "$SETTINGS_FILE" keep_hub no
            echo -e "${DIM}  Hub will shut down when the last session exits.${NC}"
            ;;
        *)
            printf "%s  Keep-hub setting unchanged (%s)%s\n" "$DIM" "$_cur_keep" "$NC"
            ;;
    esac
}

setup_step_model_volume() {
    local _cur_mvol; _cur_mvol=$(read_setting model_volume)
    local _mvol_input; _mvol_input=$(ui_yesno "Fast model storage" \
        "Fast model storage — cache the model in a Docker volume?" \
        "The engine loads the model from the Docker VM's native disk instead of
the much slower Windows filesystem bridge — engine cold starts drop from
minutes to seconds. Costs a one-time copy per model and duplicates the
active model's disk usage inside the Docker VM.
Reclaim the space any time with: docker volume rm ai-coder-models" \
        "Use fast model storage? [y/n, Enter to keep]:" \
        "$_cur_mvol" "$_cur_mvol")
    case "$_mvol_input" in
        yes)
            write_pref "$SETTINGS_FILE" model_volume yes
            echo -e "${ICON_OK} Fast model storage ${GREEN}enabled${NC} — model syncs on next engine start."
            ;;
        no)
            write_pref "$SETTINGS_FILE" model_volume no
            echo -e "${DIM}  Fast model storage disabled — engine mounts the host model folder directly.${NC}"
            echo -e "${DIM}  Reclaim volume space with: docker volume rm ai-coder-models${NC}"
            ;;
        *)
            printf "%s  Fast model storage unchanged (%s)%s\n" "$DIM" "$_cur_mvol" "$NC"
            ;;
    esac
}

setup_step_spec_decode() {
    local _cur_spec; _cur_spec=$(read_setting spec_decode)
    setup_toggle_pref spec_decode "Speculative decoding" \
        "Speculative decoding — speed up generation with a small draft model?" \
        "A tiny draft model proposes tokens the main model verifies in one pass —
typically 1.5-2x faster code generation. Costs ~1-2GB extra VRAM.
Applies only to model families that define an external draft (currently
Qwen3 and Qwen3.8). Gemma 4 and Qwen3.6 MTP always use their own built-in
MTP draft heads baked into the main model regardless of this setting —
there's no toggle for those." \
        "Use speculative decoding? [Y/n]:" \
        "$_cur_spec" "$_cur_spec" \
        "${ICON_OK} Speculative decoding ${GREEN}enabled${NC} — draft downloads on next launch." \
        "${DIM}  Speculative decoding disabled.${NC}"
}

setup_step_speed_tracking() {
    local _cur_speed; _cur_speed=$(read_setting speed_tracking)
    setup_toggle_pref speed_tracking "Generation speed tracking" \
        "Generation speed tracking — measure generation speed with llama-bench?" \
        "Runs a one-shot llama-bench pass against your model on a clean GPU and
reports tokens-per-second (tg = generation, pp = prompt processing).
Enable it, then measure any time with: ai --speed" \
        "Enable generation speed tracking? [y/N]:" \
        "$_cur_speed" "$_cur_speed" \
        "${ICON_OK} Generation speed tracking ${GREEN}enabled${NC} — measure with ${CYAN}ai --speed${NC}." \
        "${DIM}  Generation speed tracking disabled.${NC}"
}

setup_step_expose_port() {
    local _cur_expose; _cur_expose=$(read_setting expose_host_port)
    setup_toggle_pref expose_host_port "Host port exposure" \
        "Host port exposure — publish the $(engine_display_name) engine on localhost:${ENGINE_PORT}?" \
        "Allows external applications (e.g. Open WebUI) to connect directly.
Leave disabled if you only need the AI coding tools inside Docker." \
        "Expose engine on localhost:${ENGINE_PORT}? [y/N]:" \
        "$_cur_expose" "$_cur_expose" \
        "${ICON_OK} Engine will be published on ${CYAN}localhost:${ENGINE_PORT}${NC}.
${DIM}  Next launch will also offer to start Open WebUI alongside your agent.${NC}" \
        "${DIM}  Engine port not exposed to host.${NC}"
}

setup_step_git_identity() {
    local _cur_git_email; _cur_git_email=$(read_setting git_email)
    local _cur_git_name;  _cur_git_name=$(read_setting git_name)
    [ -z "$_cur_git_email" ] && _cur_git_email=$(git config --global user.email 2>/dev/null || true)
    [ -z "$_cur_git_name" ]  && _cur_git_name=$(git config --global user.name 2>/dev/null || true)

    local _git_email_input; _git_email_input=$(ui_input "Git identity — email" \
        "Git Identity (1/2): Email" \
        "Used for commits inside containers. Leave blank to keep current." \
        "Email:" \
        "$_cur_git_email" \
        "$_cur_git_email")

    local _git_name_input; _git_name_input=$(ui_input "Git identity — name" \
        "Git Identity (2/2): Name" \
        "Used for commits inside containers. Leave blank to keep current." \
        "Name:" \
        "$_cur_git_name" \
        "$_cur_git_name")

    local _final_git_email="${_git_email_input:-$_cur_git_email}"
    local _final_git_name="${_git_name_input:-$_cur_git_name}"
    if [ -n "$_final_git_email" ] || [ -n "$_final_git_name" ]; then
        if [[ "$_final_git_email" != "$_cur_git_email" || "$_final_git_name" != "$_cur_git_name" ]]; then
            touch "$USER_DIR/.rebuild-needed"
            echo -e "${YELLOW}  Note: Git identity changed. A rebuild (ai --rebuild) is required to bake this into the image.${NC}"
        fi
        write_pref "$SETTINGS_FILE" git_email "$_final_git_email"
        write_pref "$SETTINGS_FILE" git_name  "$_final_git_name"
        echo -e "${ICON_OK} Git identity saved."
    else
        echo -e "${DIM}  No git identity set — commits will use container defaults.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# cmd_setup — first-time and re-configuration wizard
#
# Model-affecting choices (context level, KV cache type, VRAM overhead
# reserve, CPU offload threshold, SGLang memory fraction) are deliberately
# not steps here: they change which model tier fits, so the --model flow
# re-prompts them instead.
# ------------------------------------------------------------------------------
cmd_setup() {
    # Ensure gum is available before initializing the UI
    ensure_gum
    ui_init

    clear
    echo -e "${CYAN}${BOLD}==========================================================${NC}"
    echo -e "${CYAN}${BOLD}                  AI-CODER SETUP WIZARD                   ${NC}"
    echo -e "${CYAN}${BOLD}==========================================================${NC}"
    echo -e "${DIM}Configure your local agent environment and preferences.${NC}"

    setup_step_alias
    setup_step_proxy
    setup_step_network
    setup_step_engine
    setup_step_gpu
    setup_step_mcp_extras
    setup_step_keep_hub
    setup_step_model_volume
    # llama.cpp-only steps (setup_step_engine has already updated
    # ENGINE_BACKEND, so these follow the engine just chosen).
    if ! engine_is_sglang; then
        setup_step_spec_decode
        setup_step_speed_tracking
    fi
    setup_step_expose_port
    setup_step_git_identity

    # Guarantee settings.json exists before arming the first-run gate: the
    # steps above write prefs per answer, so a user who accepts every default
    # still lands here with at least one key — but write the version stamp
    # explicitly so the file can never be absent after a completed --setup
    # (a missing settings.json would re-trigger the gate in ai-coder).
    write_pref "$SETTINGS_FILE" "settings_version" "$SETTINGS_SCHEMA_VERSION"
    touch "$USER_DIR/.setup-done"
    echo -e "\n${ICON_OK} Setup complete."
}
