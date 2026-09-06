#!/bin/bash
# ==============================================================================
# AI-CODER-DETECT-ENV.SH | Minimal WSL/Git Bash Platform Detection
# Sets IS_WSL and IS_GITBASH. Self-contained like ai-coder-graphics.sh — no
# dependency on any other ai-coder global — since this is sourced both by the
# full launch chain (ai-coder-core.sh) and by standalone entry points that run
# before or without it (ai-coder-status-common.sh, offline/unbundle.sh).
# Idempotent — safe to source multiple times in the same shell.
# ==============================================================================
[ "${_AI_CODER_DETECT_ENV_LOADED:-}" = "1" ] && return 0
readonly _AI_CODER_DETECT_ENV_LOADED=1

IS_WSL=$(grep -qi Microsoft /proc/version 2>/dev/null && echo "true" || echo "false")
# $OSTYPE (a bash builtin) is always "msys" under Git-for-Windows' bash,
# regardless of what `uname -s` reports (MINGW64_NT-..., MSYS_NT-..., etc.
# depending on how the shell was launched).
IS_GITBASH=$([[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]] && echo "true" || echo "false")
