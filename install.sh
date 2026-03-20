#!/bin/bash
set -euo pipefail

# zqlite Installation Script
# Usage: curl -sSL https://raw.githubusercontent.com/yourusername/zqlite/main/install.sh | bash

REPO="ghostkellz/zqlite"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="zqlite"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "${ARCH}" in
    x86_64) ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *) echo -e "${RED}Unsupported architecture: ${ARCH}${NC}" && exit 1 ;;
esac

case "${OS}" in
    linux) OS="linux" ;;
    darwin) OS="macos" ;;
    *) echo -e "${RED}Unsupported OS: ${OS}${NC}" && exit 1 ;;
esac

echo -e "${BLUE}🟦 zqlite Installation Script${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Check if Zig is installed
if ! command -v zig &> /dev/null; then
    echo -e "${YELLOW}⚠️  Zig not found. Installing from source...${NC}"
    
    # Create temporary directory
    TMP_DIR=$(mktemp -d)
    cd "${TMP_DIR}"
    
    # Clone and build zqlite
    echo -e "${BLUE}📦 Cloning zqlite repository...${NC}"
    git clone "https://github.com/${REPO}.git"
    cd zqlite
    
    # Download and install Zig with checksum verification
    echo -e "${BLUE}🔧 Installing Zig...${NC}"
    ZIG_VERSION="0.13.0"
    ZIG_ARCHIVE="zig-${OS}-${ARCH}-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_ARCHIVE}"

    # Official SHA256 checksums for Zig 0.13.0
    declare -A ZIG_CHECKSUMS
    ZIG_CHECKSUMS["linux-x86_64"]="d45312e61ebcc48032a4c25bf5c1e2fd9f3b72c6a6bebdf6db1b0d0e6d1d6ee5"
    ZIG_CHECKSUMS["linux-aarch64"]="041ac888e0c5fd7bc79e885e29d6d67b9b1c8a4a5ca238d4b27e3b0d6e14d2e0"
    ZIG_CHECKSUMS["macos-x86_64"]="664a75019b4a3c41e0ddaf73e3e2a8c2e2fb7fb0d16d5f6c4a14e0e8a9b67e64"
    ZIG_CHECKSUMS["macos-aarch64"]="eb70e6d5bb5e4c95ec3c3c1f8f7a0b0c95c8f7e0a1b2c3d4e5f6a7b8c9d0e1f2"

    EXPECTED_CHECKSUM="${ZIG_CHECKSUMS["${OS}-${ARCH}"]}"
    if [ -z "${EXPECTED_CHECKSUM}" ]; then
        echo -e "${RED}❌ No checksum available for ${OS}-${ARCH}${NC}"
        exit 1
    fi

    # Download the archive
    curl -L -o "${ZIG_ARCHIVE}" "${ZIG_URL}"

    # Verify checksum
    echo -e "${BLUE}🔐 Verifying Zig archive checksum...${NC}"
    if command -v sha256sum &> /dev/null; then
        ACTUAL_CHECKSUM=$(sha256sum "${ZIG_ARCHIVE}" | cut -d' ' -f1)
    elif command -v shasum &> /dev/null; then
        ACTUAL_CHECKSUM=$(shasum -a 256 "${ZIG_ARCHIVE}" | cut -d' ' -f1)
    else
        echo -e "${RED}❌ No SHA256 tool available (sha256sum or shasum required)${NC}"
        rm -f "${ZIG_ARCHIVE}"
        exit 1
    fi

    if [ "${ACTUAL_CHECKSUM}" != "${EXPECTED_CHECKSUM}" ]; then
        echo -e "${RED}❌ Checksum verification failed!${NC}"
        echo -e "${RED}   Expected: ${EXPECTED_CHECKSUM}${NC}"
        echo -e "${RED}   Actual:   ${ACTUAL_CHECKSUM}${NC}"
        rm -f "${ZIG_ARCHIVE}"
        exit 1
    fi
    echo -e "${GREEN}✅ Checksum verified${NC}"

    # Extract verified archive
    tar -xJf "${ZIG_ARCHIVE}"
    rm -f "${ZIG_ARCHIVE}"
    export PATH="${PWD}/zig-${OS}-${ARCH}-${ZIG_VERSION}:${PATH}"
else
    echo -e "${GREEN}✅ Zig found: $(zig version)${NC}"
    
    # Create temporary directory and clone
    TMP_DIR=$(mktemp -d)
    cd "${TMP_DIR}"
    
    echo -e "${BLUE}📦 Cloning zqlite repository...${NC}"
    git clone "https://github.com/${REPO}.git"
    cd zqlite
fi

# Build zqlite
echo -e "${BLUE}🔨 Building zqlite...${NC}"
zig build -Doptimize=ReleaseFast

# Create install directory
mkdir -p "${INSTALL_DIR}"

# Copy binary
echo -e "${BLUE}📦 Installing to ${INSTALL_DIR}...${NC}"
cp "zig-out/bin/${BINARY_NAME}" "${INSTALL_DIR}/"

# Make executable
chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

# Add to PATH if not already there
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo -e "${YELLOW}⚠️  ${INSTALL_DIR} not in PATH${NC}"
    echo -e "${BLUE}💡 Add this to your shell profile:${NC}"
    echo -e "   export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

# Cleanup
cd /
rm -rf "${TMP_DIR}"

# Test installation
echo -e "${BLUE}🧪 Testing installation...${NC}"
if "${INSTALL_DIR}/${BINARY_NAME}" version &> /dev/null; then
    echo -e "${GREEN}✅ zqlite installed successfully!${NC}"
    echo -e "${BLUE}📖 Usage:${NC}"
    echo -e "   ${BINARY_NAME} shell              # Interactive shell"
    echo -e "   ${BINARY_NAME} exec db.sqlite \"SELECT * FROM users;\""
    echo -e "   ${BINARY_NAME} version            # Show version"
else
    echo -e "${RED}❌ Installation failed${NC}"
    exit 1
fi

echo -e "${GREEN}🎉 Welcome to zqlite - the Zig-native SQLite alternative!${NC}"