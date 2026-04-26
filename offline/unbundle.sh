#!/bin/bash
# ==============================================================================
# UNBUNDLE.SH v1.0 | Offline Bundle Installer
# Loads a pre-built AI-Coder bundle onto an isolated (air-gapped) system.
#
# Run this script from the root of the bundle directory:
#   cd /path/to/bundle
#   ./unbundle.sh
#
# What it does:
#   1. Prompts for an install directory for the ai-coder scripts
#   2. Loads all Docker images from images/*.tar.gz into the local daemon
#   3. Copies the model file into ~/ai-models/ (shared with ai-coder-core.sh)
#   4. Copies scripts into the chosen install directory
#
# Prerequisites: Docker Desktop must be installed and running.
# No internet connection is required.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
IMAGES_DIR="$SCRIPT_DIR/images"
MODELS_DIR="$SCRIPT_DIR/models"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
MANIFEST_FILE="$SCRIPT_DIR/bundle.manifest"

# --- [ Environment detection (standalone — no core.sh dependency) ] -----------
IS_WSL="false"
IS_GITBASH="false"
grep -qi Microsoft /proc/version 2>/dev/null && IS_WSL="true" || true
expr "$(uname -s)" : '.*MINGW.*' >/dev/null 2>&1 && IS_GITBASH="true" || true

# Resolve model storage directory — mirrors the logic in ai-coder-core.sh so
# ai-coder finds the model in the same place it always looks.
if [ "$IS_WSL" = "true" ]; then
    _win_home=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n' || true)
    if [ -n "${_win_home:-}" ]; then
        MODEL_STORAGE_DIR="$(wslpath "$_win_home")/ai-models"
    else
        MODEL_STORAGE_DIR="$HOME/ai-models"
    fi
else
    MODEL_STORAGE_DIR="$HOME/ai-models"
fi

# --- [ Banner ] ---------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       AI-CODER OFFLINE UNBUNDLE v1.0         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# --- [ Verify bundle layout ] -------------------------------------------------
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "✘  bundle.manifest not found."
    echo "   Run unbundle.sh from the root of the bundle directory."
    exit 1
fi
[ -d "$IMAGES_DIR" ]  || { echo "✘  images/ directory not found.";  exit 1; }
[ -d "$MODELS_DIR" ]  || { echo "✘  models/ directory not found.";  exit 1; }
[ -d "$SCRIPTS_DIR" ] || { echo "✘  scripts/ directory not found."; exit 1; }

MODEL_FILE=$(grep '^model_file='  "$MANIFEST_FILE" | cut -d= -f2-)
MODEL_DESC=$(grep '^model_desc='  "$MANIFEST_FILE" | cut -d= -f2-)
BUNDLE_DATE=$(grep '^bundle_date=' "$MANIFEST_FILE" | cut -d= -f2- || echo "unknown")

echo "  Bundle date : $BUNDLE_DATE"
echo "  Model       : $MODEL_DESC"
echo "  Model path  : $MODEL_STORAGE_DIR/$MODEL_FILE"
echo ""

# --- [ Docker check ] ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "✘  Docker CLI not found in PATH."
    echo "   Install Docker Desktop and ensure it is running, then retry."
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "✘  Docker daemon is not running."
    echo "   Start Docker Desktop and retry."
    exit 1
fi
echo "✔  Docker is running."

# --- [ Load Docker images ] ---------------------------------------------------
echo ""
echo "► Loading Docker images (this may take several minutes)..."
_img_count=0
for _tar in "$IMAGES_DIR"/*.tar.gz; do
    [ -f "$_tar" ] || continue
    echo "  Loading $(basename "$_tar")..."
    docker load < "$_tar"
    _img_count=$((_img_count + 1))
done

if [ "$_img_count" -eq 0 ]; then
    echo "✘  No image archives found in images/."
    exit 1
fi
echo "✔  Loaded ${_img_count} image archive(s)."

# --- [ Install model ] --------------------------------------------------------
echo ""
echo "► Installing model..."
mkdir -p "$MODEL_STORAGE_DIR"

_model_src="$MODELS_DIR/$MODEL_FILE"
_model_dst="$MODEL_STORAGE_DIR/$MODEL_FILE"

if [ ! -f "$_model_src" ]; then
    echo "✘  Model file not found in bundle: $MODEL_FILE"
    echo "   The bundle may be incomplete. Re-run bundle.sh on the source machine."
    exit 1
fi

if [ -f "$_model_dst" ]; then
    echo "  Already installed — skipping copy."
    echo "  ($MODEL_FILE)"
else
    echo "  Copying to $_model_dst..."
    cp "$_model_src" "$_model_dst"
    echo "✔  Model installed."
fi

# --- [ Script install directory ] --------------------------------------------
# Accepts Windows paths (C:\foo\bar), Git Bash (/c/foo/bar), or POSIX paths.
normalize_path() {
    local raw="$1"
    # Strip surrounding quotes the user may have typed
    raw="${raw%\"}"
    raw="${raw#\"}"
    raw="${raw%\'}"
    raw="${raw#\'}"
    # Expand ~ manually (read -r suppresses tilde expansion)
    raw="${raw/#\~/$HOME}"
    # Windows absolute path: C:\... or C:/...
    if [[ "$raw" =~ ^[A-Za-z]:[/\\] ]]; then
        local drive letter rest
        drive="${raw:0:2}"           # e.g. C:
        letter="${drive:0:1}"
        rest="${raw:2}"             # everything after the colon
        rest="${rest//\\//}"        # backslash → forward slash
        rest="${rest#/}"            # strip leading /
        if [ "$IS_WSL" = "true" ]; then
            raw="/mnt/${letter,,}/$rest"
        else
            raw="/${letter,,}/$rest"
        fi
    else
        # Already POSIX — just normalise backslashes just in case
        raw="${raw//\\//}"
    fi
    echo "$raw"
}

echo ""
echo "► Script installation directory"
echo "  Enter the path where ai-coder scripts should be installed."
echo "  Accepts Windows (C:\\path), Git Bash (/c/path), or POSIX (/home/...) paths."
echo "  Press Enter to use the default: ~/ai-coder"
echo -n "  Install path: "
read -r _raw_install_dir

if [ -z "$_raw_install_dir" ]; then
    INSTALL_DIR="$HOME/ai-coder"
else
    INSTALL_DIR="$(normalize_path "$_raw_install_dir")"
fi

echo "  Installing to: $INSTALL_DIR"

if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/ai-coder" ]; then
    echo ""
    echo -n "  Directory already exists. Overwrite? [y/N]: "
    read -r _overwrite
    case "${_overwrite,,}" in
        y|yes) ;;
        *) echo "  Skipping script installation."; INSTALL_DIR="" ;;
    esac
fi

if [ -n "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    cp -r "$SCRIPTS_DIR"/. "$INSTALL_DIR/"
    # Ensure scripts are executable
    chmod +x "$INSTALL_DIR/ai-coder" "$INSTALL_DIR/ai-status.sh" 2>/dev/null || true
    find "$INSTALL_DIR/agents" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
    find "$INSTALL_DIR/libs"   -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
    echo "✔  Scripts installed."
fi

# --- [ Done ] -----------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✔  Unbundle complete!                       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if [ -n "$INSTALL_DIR" ]; then
    echo "To launch AI-Coder:"
    echo ""
    echo "  cd \"$INSTALL_DIR\""
    echo "  ./ai-coder"
    echo ""
    echo "To create the 'ai' shell alias (run once):"
    echo "  ./ai-coder --setup-path"
    if [ "$IS_GITBASH" = "true" ]; then
        echo "  source ~/.bash_profile"
    else
        echo "  source ~/.bashrc"
    fi
else
    echo "Scripts were not copied. You can run directly from:"
    echo "  cd \"$SCRIPTS_DIR\""
    echo "  ./ai-coder"
fi
echo ""
echo "Note: No internet connection is required to run ai-coder."
