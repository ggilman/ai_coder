#!/bin/bash
# ==============================================================================
# INSTALL.SH | ai-coder Bootstrap Installer
# ==============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash
#       Installs to ~/ai-coder (default).
#
#   curl -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash -s -- ~/my-dir
#       Installs to ~/my-dir (any absolute or relative path).
#
#   curl -fsSL https://raw.githubusercontent.com/ggilman/ai_coder/release/install.sh | bash -s -- .
#       Installs into the current directory.
# ==============================================================================
set -euo pipefail

NC='\033[0m'; BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'
ICON_OK=" ${GREEN}✔${NC} "; ICON_GEAR=" ${CYAN}⚙${NC} "

TARBALL_URL="https://github.com/ggilman/ai_coder/archive/refs/heads/release.tar.gz"
API_URL="https://api.github.com/repos/ggilman/ai_coder/git/refs/heads/release"
INSTALL_DIR="${1:-$HOME/ai-coder}"

echo -e "\n${BOLD}ai-coder installer${NC}\n"

# --- [ preflight ] ------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo -e "${RED}✘ Neither curl nor wget found — install one and retry.${NC}"; exit 1
fi

if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}⚠ Directory already exists and is not empty: ${CYAN}${INSTALL_DIR}${NC}"
    printf "  Overwrite? [y/N]: "
    read -r _confirm
    case "${_confirm,,}" in
        y|yes) ;;
        *) echo -e "${NC}Aborted."; exit 0 ;;
    esac
fi

mkdir -p "$INSTALL_DIR"

# --- [ download & extract ] ---------------------------------------------------

echo -e "${ICON_GEAR}Downloading release..."
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 "$TARBALL_URL" | tar xz --strip-components=1 -C "$tmp_dir" || {
        echo -e "${RED}✘ Download failed${NC}"; exit 1
    }
else
    wget -qO- --timeout=30 "$TARBALL_URL" | tar xz --strip-components=1 -C "$tmp_dir" || {
        echo -e "${RED}✘ Download failed${NC}"; exit 1
    }
fi

# --- [ install ] --------------------------------------------------------------

echo -e "${ICON_GEAR}Installing to ${CYAN}${INSTALL_DIR}${NC}..."

rm -rf "$INSTALL_DIR/agents" "$INSTALL_DIR/libs" "$INSTALL_DIR/packages" "$INSTALL_DIR/offline"
rm -f  "$INSTALL_DIR/ai-coder" "$INSTALL_DIR/ai-status.sh" \
       "$INSTALL_DIR/LICENSE"  "$INSTALL_DIR/README.md" \
       "$INSTALL_DIR/.gitignore" "$INSTALL_DIR/.gitattributes" "$INSTALL_DIR/.editorconfig" \
       "$INSTALL_DIR/config/ai-coder-model.conf"

if [ -d "$tmp_dir/config/families" ]; then
    for _f in "$tmp_dir/config/families"/*; do
        [ -f "$_f" ] && rm -f "$INSTALL_DIR/config/families/$(basename "$_f")"
    done
fi

cp -r "$tmp_dir/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/ai-coder" "$INSTALL_DIR/ai-status.sh"

# --- [ record release hash ] --------------------------------------------------

release_hash=""
if command -v curl >/dev/null 2>&1; then
    release_hash=$(curl -fsSL --connect-timeout 4 "$API_URL" 2>/dev/null \
        | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]{40}"' \
        | head -1 | grep -oE '[a-f0-9]{40}') || true
else
    release_hash=$(wget -qO- --timeout=4 "$API_URL" 2>/dev/null \
        | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]{40}"' \
        | head -1 | grep -oE '[a-f0-9]{40}') || true
fi
[ -n "$release_hash" ] && printf '%s\n' "$release_hash" > "$HOME/.ai-coder-release-hash"

# --- [ done ] -----------------------------------------------------------------

echo -e "${ICON_OK}Installed.\n"
echo -e "  Next step: ${CYAN}${INSTALL_DIR}/ai-coder --setup${NC}"
echo -e "  To add a shell alias, --setup will offer to add ${CYAN}ai${NC} to your profile.\n"
