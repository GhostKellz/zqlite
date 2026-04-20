#!/usr/bin/env bash
set -euo pipefail

# zqlite installation script
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ghostkellz/zqlite/refs/heads/main/install.sh | bash

REPO="ghostkellz/zqlite"
DEFAULT_REF="main"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="zqlite"
MIN_ZIG_VERSION="0.17.0-dev.27+0dd99c37c"
RELEASE_API="https://api.github.com/repos/${REPO}/releases/tags"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

download() {
    curl -fsSL "$1" -o "$2"
}

version_ge() {
    [ "$1" = "$2" ] && return 0
    local highest
    highest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
    [ "$highest" = "$1" ]
}

REF="${ZQLITE_REF:-$DEFAULT_REF}"
USE_SOURCE_INSTALL="${ZQLITE_SOURCE_INSTALL:-0}"

echo -e "${BLUE}zqlite install${NC}"
echo -e "${YELLOW}ref: ${REF}${NC}"

for cmd in curl tar; do
    if ! have_cmd "$cmd"; then
        echo -e "${RED}Missing required command: ${cmd}${NC}"
        exit 1
    fi
done

install_from_release() {
    local ref="$1"
    local target="x86_64-unknown-linux-gnu"
    local archive="zqlite-${ref}-${target}.tar.gz"
    local checksum_file="${archive}.sha256"
    local archive_url="https://github.com/${REPO}/releases/download/${ref}/${archive}"
    local checksum_url="https://github.com/${REPO}/releases/download/${ref}/${checksum_file}"

    echo -e "${BLUE}Attempting release install for ${ref}...${NC}"
    download "$archive_url" "$archive"
    download "$checksum_url" "$checksum_file"
    sha256sum -c "$checksum_file"
    tar -xzf "$archive"

    mkdir -p "${INSTALL_DIR}"
    install -m 0755 "zqlite-${ref}-${target}/bin/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
}

install_from_source() {
    for cmd in git zig; do
        if ! have_cmd "$cmd"; then
            echo -e "${RED}Missing required command for source install: ${cmd}${NC}"
            exit 1
        fi
    done

    ZIG_VERSION=$(zig version)
    if ! version_ge "$ZIG_VERSION" "$MIN_ZIG_VERSION"; then
        echo -e "${RED}Zig ${ZIG_VERSION} is too old.${NC}"
        echo -e "${YELLOW}Required: ${MIN_ZIG_VERSION} or newer.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Using Zig ${ZIG_VERSION}${NC}"

    echo -e "${BLUE}Cloning repository...${NC}"
    git clone --depth 1 --branch "${REF}" "https://github.com/${REPO}.git" zqlite
    cd zqlite

    echo -e "${BLUE}Building zqlite...${NC}"
    zig build -Doptimize=ReleaseFast

    mkdir -p "${INSTALL_DIR}"
    install -m 0755 "zig-out/bin/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
}

TMP_DIR=$(mktemp -d)
cd "${TMP_DIR}"

if [ "$USE_SOURCE_INSTALL" = "1" ]; then
    install_from_source
elif [[ "$REF" == v* ]]; then
    if ! install_from_release "$REF"; then
        echo -e "${YELLOW}Release artifact install failed, falling back to source build.${NC}"
        cd "${TMP_DIR}"
        install_from_source
    fi
else
    install_from_source
fi

echo -e "${BLUE}Running install smoke test...${NC}"
"${INSTALL_DIR}/${BINARY_NAME}" --version >/dev/null
"${INSTALL_DIR}/${BINARY_NAME}" --help >/dev/null

echo -e "${GREEN}Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}${NC}"

if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo -e "${YELLOW}${INSTALL_DIR} is not in PATH${NC}"
    echo "Add this to your shell profile:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

echo
echo "Examples:"
echo "  ${BINARY_NAME} --help"
echo "  ${BINARY_NAME} --version"
echo "  ${BINARY_NAME} mydb.db"
echo "  ${BINARY_NAME} --sql \"SELECT 1+1\""
