#!/bin/sh
set -eu

# snag installer — downloads the latest binary and adds ~/.local/snag/bin to PATH

REPO="resetself/snag"
BIN_DIR="${HOME}/.local/snag/bin"
SNG_DIR="${HOME}/.local/snag"

# Detect platform
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

echo "→ Installing snag..."
echo "  platform: ${ARCH_NAME}-${PLATFORM}"

# Download
mkdir -p "$BIN_DIR"
curl -sL "$URL" -o "${BIN_DIR}/snag"
chmod +x "${BIN_DIR}/snag"

echo "✓ snag installed to ${BIN_DIR}/snag"

# PATH setup
SHELL_NAME=$(basename "${SHELL:-$SHELL}")
case "$SHELL_NAME" in
    fish)
        SHELL_CONFIG="${HOME}/.config/fish/config.fish"
        PATH_LINE="fish_add_path ${BIN_DIR}"
        ;;
    zsh)
        SHELL_CONFIG="${HOME}/.zshrc"
        PATH_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
        ;;
    bash)
        SHELL_CONFIG="${HOME}/.bashrc"
        PATH_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
        ;;
    *)
        SHELL_CONFIG="your shell config"
        PATH_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
        ;;
esac

if ! echo "$PATH" | tr ':' '\n' | grep -qF "$BIN_DIR"; then
    echo ""
    echo "→ Add ${BIN_DIR} to your PATH:"
    echo ""
    echo "  echo '${PATH_LINE}' >> ${SHELL_CONFIG}"
    echo "  source ${SHELL_CONFIG}"
    echo ""
    echo "  Or run this one-liner:"
    echo "  echo '${PATH_LINE}' >> ${SHELL_CONFIG} && source ${SHELL_CONFIG}"
fi

echo ""
echo "Done. Try: snag list"
