#!/bin/bash
# ==============================================================================
# AI-CODER-DETECT-ENV.SH | Minimal WSL/Git Bash Platform Detection
# Sets IS_WSL and IS_GITBASH, and provides resolve_model_storage_dir
# (WIN_HOME / MODEL_STORAGE_DIR). Self-contained like ai-coder-graphics.sh —
# no dependency on any other ai-coder global — since this is sourced both by
# the full launch chain (ai-coder-core.sh) and by standalone entry points that
# run before or without it (ai-coder-status-common.sh, offline/unbundle.sh).
# Idempotent — safe to source multiple times in the same shell.
# ==============================================================================
[ "${_AI_CODER_DETECT_ENV_LOADED:-}" = "1" ] && return 0
readonly _AI_CODER_DETECT_ENV_LOADED=1

IS_WSL=$(grep -qi Microsoft /proc/version 2>/dev/null && echo "true" || echo "false")
# $OSTYPE (a bash builtin) is always "msys" under Git-for-Windows' bash,
# regardless of what `uname -s` reports (MINGW64_NT-..., MSYS_NT-..., etc.
# depending on how the shell was launched).
IS_GITBASH=$([[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && echo "true" || echo "false")

# ------------------------------------------------------------------------------
# resolve_model_storage_dir — set WIN_HOME and MODEL_STORAGE_DIR
#
# Single source of truth for where ai-coder reads/writes models; called by both
# ai-coder-core.sh and offline/unbundle.sh so every entry point agrees. Windows
# home so WSL and Git Bash share the same folder: Git Bash $HOME is already the
# Windows home (/c/Users/...), WSL queries the Windows USERPROFILE via cmd.exe
# and converts with wslpath. WIN_HOME is also the base for other cross-shell
# shared paths (e.g. .ai-coder-env). A pre-set MODEL_STORAGE_DIR (exported env
# var) always wins.
# ------------------------------------------------------------------------------
resolve_model_storage_dir() {
    WIN_HOME="$HOME"
    if [ "$IS_WSL" = "true" ]; then
        local _win_home
        _win_home=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n' || true)
        if [ -n "${_win_home:-}" ]; then
            WIN_HOME="$(wslpath "$_win_home")"
            MODEL_STORAGE_DIR="$WIN_HOME/ai-models"
        else
            MODEL_STORAGE_DIR="${MODEL_STORAGE_DIR:-$HOME/ai-models}"
        fi
    else
        MODEL_STORAGE_DIR="${MODEL_STORAGE_DIR:-$HOME/ai-models}"
    fi
}
