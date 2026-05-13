#!/bin/sh
set -eu

REPO="resetself/snag"
BIN_DIR="${HOME}/.local/snag/bin"

OS=$(uname -s)
ARCH=$(uname -m)
case "$OS" in
    Darwin)  PLATFORM="macos" ;;
    Linux)   PLATFORM="linux" ;;
    *)       echo "Unsupported OS: $OS"; exit 1 ;;
esac
case "$ARCH" in
    x86_64|amd64) ARCH_NAME="x86_64" ;;
    arm64|aarch64) ARCH_NAME="aarch64" ;;
    *)             echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

BINARY="snag-${ARCH_NAME}-${PLATFORM}"
URL="https://github.com/${REPO}/releases/latest/download/${BINARY}"

echo "→ Installing snag (${ARCH_NAME}-${PLATFORM})..."
mkdir -p "$BIN_DIR"
curl -fsSL "$URL" -o "${BIN_DIR}/snag"
chmod +x "${BIN_DIR}/snag"
echo "✓ snag → ${BIN_DIR}/snag"

# Add to PATH
add_path() {
    local config="$1"
    local line="$2"
    if [ -f "$config" ] && grep -qF "$BIN_DIR" "$config" 2>/dev/null; then
        return
    fi
    mkdir -p "$(dirname "$config")"
    echo "$line" >> "$config"
    echo "✓ PATH added to ${config}"
}

SHELL_NAME=$(basename "${SHELL:-$SHELL}")
case "$SHELL_NAME" in
    fish) add_path "${HOME}/.config/fish/config.fish" "fish_add_path ${BIN_DIR}" ;;
    zsh)  add_path "${HOME}/.zshrc"    "export PATH=\"${BIN_DIR}:\$PATH\"" ;;
    bash) add_path "${HOME}/.bashrc"   "export PATH=\"${BIN_DIR}:\$PATH\"" ;;
    *)    add_path "${HOME}/.profile"  "export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

echo ""
echo "Done. Restart your shell or run: source ~/.$(basename "$SHELL_NAME")rc"
echo "Then try: snag --help"
