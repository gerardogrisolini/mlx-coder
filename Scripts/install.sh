#!/usr/bin/env bash
set -euo pipefail

REPO="gerardogrisolini/mlx-server"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
FEATURES_DIR="${FEATURES_DIR:-${INSTALL_DIR}/mlx-server-features}"

echo "mlx-server installer"
echo ""

# Determine latest release
if command -v curl &>/dev/null; then
    FETCH="curl -sL"
elif command -v wget &>/dev/null; then
    FETCH="wget -qO-"
else
    echo "Error: curl or wget is required." >&2
    exit 1
fi

# Find the latest tag
LATEST_TAG=$($FETCH "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "${LATEST_TAG:-}" ]; then
    echo "Error: could not determine the latest release." >&2
    echo "Visit https://github.com/${REPO}/releases to download manually." >&2
    exit 1
fi

echo "Latest release: ${LATEST_TAG}"

ARCHIVE="mlx-server-${LATEST_TAG}-macos-arm64.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ARCHIVE}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading ${ARCHIVE}..."
$FETCH "$DOWNLOAD_URL" -o "${TMPDIR}/${ARCHIVE}"

# Verify checksum if available
CHECKSUM_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ARCHIVE}.sha256"
if $FETCH "$CHECKSUM_URL" -o "${TMPDIR}/${ARCHIVE}.sha256" 2>/dev/null; then
    echo "Verifying checksum..."
    (cd "$TMPDIR" && shasum -a 256 -c "${ARCHIVE}.sha256") || {
        echo "Error: checksum verification failed!" >&2
        exit 1
    }
else
    echo "Warning: checksum file not found, skipping verification."
fi

echo "Extracting..."
tar xzf "${TMPDIR}/${ARCHIVE}" -C "${TMPDIR}"

# Create install directories
sudo mkdir -p "$INSTALL_DIR"
sudo mkdir -p "$FEATURES_DIR"

# Install main binaries
sudo cp "${TMPDIR}/mlx-server" "${INSTALL_DIR}/mlx-server"
sudo cp "${TMPDIR}/mlx-coder" "${INSTALL_DIR}/mlx-coder"
sudo chmod +x "${INSTALL_DIR}/mlx-server" "${INSTALL_DIR}/mlx-coder"

# Install feature binaries
if [ -d "${TMPDIR}/features" ]; then
    for feature in "${TMPDIR}/features/"*; do
        [ -f "$feature" ] || continue
        sudo cp "$feature" "${FEATURES_DIR}/"
        sudo chmod +x "${FEATURES_DIR}/$(basename "$feature")"
    done
    echo "Features installed to ${FEATURES_DIR}/"
fi

echo ""
echo "✓ mlx-server ${LATEST_TAG} installed successfully!"
echo ""
echo "  mlx-server   → ${INSTALL_DIR}/mlx-server"
echo "  mlx-coder    → ${INSTALL_DIR}/mlx-coder"
echo "  features     → ${FEATURES_DIR}/"
echo ""
echo "Make sure ${INSTALL_DIR} is in your PATH."
