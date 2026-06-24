#!/usr/bin/env bash
set -euo pipefail

# zqlite installation script
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ghostkellz/zqlite/refs/heads/main/install.sh -o install.sh
#   chmod +x install.sh
#   ZQLITE_REF=<tag> ./install.sh

REPO="ghostkellz/zqlite"
DEFAULT_REF="main"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"
BINARY_NAME="zqlite"
MIN_ZIG_VERSION="0.17.0-dev.931+84f84267c"
RELEASE_API="https://api.github.com/repos/${REPO}/releases/tags"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

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

    if [ -n "${ZQLITE_RELEASE_ARCHIVE:-}" ]; then
        echo -e "${BLUE}Installing from local release archive ${ZQLITE_RELEASE_ARCHIVE}...${NC}"
        tar -xzf "${ZQLITE_RELEASE_ARCHIVE}"
        mkdir -p "${INSTALL_DIR}"
        install -m 0755 "package/bin/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
        return 0
    fi

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

    if [ -n "${ZQLITE_LOCAL_SOURCE:-}" ]; then
        echo -e "${BLUE}Using local source ${ZQLITE_LOCAL_SOURCE}...${NC}"
        mkdir zqlite
        tar \
            --exclude .git \
            --exclude .zig-cache \
            --exclude zig-out \
            -C "${ZQLITE_LOCAL_SOURCE}" \
            -cf - . | tar -xf - -C zqlite
    else
        echo -e "${BLUE}Cloning repository...${NC}"
        git clone --depth 1 --branch "${REF}" "https://github.com/${REPO}.git" zqlite
    fi
    cd zqlite

    echo -e "${BLUE}Building zqlite...${NC}"
    zig build -Doptimize=ReleaseFast

    mkdir -p "${INSTALL_DIR}"
    install -m 0755 "zig-out/bin/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
}

if [ -n "${ZQLITE_LOCAL_SOURCE:-}" ]; then
    ZQLITE_INSTALL_CACHE_DIR="${ZQLITE_INSTALL_CACHE_DIR:-${ZQLITE_LOCAL_SOURCE%/}/.zig-cache}"
else
    ZQLITE_INSTALL_CACHE_DIR="${ZQLITE_INSTALL_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/zqlite}"
fi
mkdir -p "${ZQLITE_INSTALL_CACHE_DIR}"
WORK_DIR=$(mktemp -d "${ZQLITE_INSTALL_CACHE_DIR}/zqlite-install-script.XXXXXX")
cd "${WORK_DIR}"

if [ "$USE_SOURCE_INSTALL" = "1" ]; then
    install_from_source
elif [[ "$REF" == v* ]]; then
    if ! install_from_release "$REF"; then
        echo -e "${YELLOW}Release artifact install failed, falling back to source build.${NC}"
        cd "${WORK_DIR}"
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
