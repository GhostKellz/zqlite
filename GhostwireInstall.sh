#!/bin/bash

# GhostwireInstall.sh - ZQLite FFI Installation Script for Ghostwire Testing
# This script installs ZQLite with Rust FFI bindings without requiring the full zqlite repo clone

set -euo pipefail

# Configuration
ZQLITE_VERSION="${ZQLITE_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-./zqlite-ffi}"
GHOSTWIRE_DIR="${GHOSTWIRE_DIR:-./ghostwire}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0-dev}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    # Check for required tools
    local missing_tools=()

    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi

    if ! command -v tar &> /dev/null; then
        missing_tools+=("tar")
    fi

    if ! command -v cargo &> /dev/null; then
        missing_tools+=("cargo (Rust)")
    fi

    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and retry."
        exit 1
    fi

    log_success "All required tools found"
}

# Install Zig if not available
install_zig() {
    if command -v zig &> /dev/null; then
        local current_version
        current_version=$(zig version)
        log_info "Zig already installed: $current_version"
        return 0
    fi

    log_info "Installing Zig compiler..."

    local platform
    case "$(uname -s)" in
        Linux*)     platform="linux" ;;
        Darwin*)    platform="macos" ;;
        MINGW*)     platform="windows" ;;
        *)          log_error "Unsupported platform: $(uname -s)"; exit 1 ;;
    esac

    local arch
    case "$(uname -m)" in
        x86_64)     arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)          log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    local zig_archive="zig-${platform}-${arch}-${ZIG_VERSION}.tar.xz"
    local zig_url="https://ziglang.org/builds/${zig_archive}"
    local zig_dir="./zig-${platform}-${arch}-${ZIG_VERSION}"

    if [ ! -d "$zig_dir" ]; then
        log_info "Downloading Zig from $zig_url"
        curl -L -o "${zig_archive}" "$zig_url"

        # Fetch and verify checksum from official source
        log_info "Verifying Zig archive integrity..."
        local checksum_url="https://ziglang.org/builds/zig-${platform}-${arch}-${ZIG_VERSION}.tar.xz.sha256"
        local expected_checksum
        expected_checksum=$(curl -sL "$checksum_url" | cut -d' ' -f1)

        if [ -z "$expected_checksum" ]; then
            log_error "Could not fetch checksum from $checksum_url"
            rm -f "${zig_archive}"
            exit 1
        fi

        local actual_checksum
        if command -v sha256sum &> /dev/null; then
            actual_checksum=$(sha256sum "${zig_archive}" | cut -d' ' -f1)
        elif command -v shasum &> /dev/null; then
            actual_checksum=$(shasum -a 256 "${zig_archive}" | cut -d' ' -f1)
        else
            log_error "No SHA256 tool available (sha256sum or shasum required)"
            rm -f "${zig_archive}"
            exit 1
        fi

        if [ "$actual_checksum" != "$expected_checksum" ]; then
            log_error "Checksum verification failed!"
            log_error "Expected: $expected_checksum"
            log_error "Actual:   $actual_checksum"
            rm -f "${zig_archive}"
            exit 1
        fi
        log_success "Checksum verified"

        # Extract verified archive
        tar xJf "${zig_archive}"
        rm -f "${zig_archive}"
    fi

    # Add to PATH for this session
    export PATH="$PWD/$zig_dir:$PATH"
    log_success "Zig installed and added to PATH"
}

# Download and extract ZQLite source
download_zqlite() {
    log_info "Setting up ZQLite source..."

    if [ -d "$INSTALL_DIR" ]; then
        log_warning "ZQLite directory already exists, cleaning up..."
        rm -rf "$INSTALL_DIR"
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Download ZQLite source with integrity verification
    # SECURITY: Use specific tags/commits rather than unverified HEAD
    if [ "$ZQLITE_VERSION" = "latest" ]; then
        log_info "Downloading latest ZQLite release..."
        # Fetch latest release tag via GitHub API for reproducibility
        local latest_tag
        latest_tag=$(curl -sL "https://api.github.com/repos/ghostkellz/zqlite/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$latest_tag" ]; then
            log_warning "Could not fetch latest release tag, falling back to main branch"
            git clone --depth 1 https://github.com/ghostkellz/zqlite.git .
        else
            log_info "Using release tag: $latest_tag"
            git clone --depth 1 --branch "$latest_tag" https://github.com/ghostkellz/zqlite.git .
        fi
    else
        log_info "Downloading ZQLite version $ZQLITE_VERSION..."
        git clone --depth 1 --branch "$ZQLITE_VERSION" https://github.com/ghostkellz/zqlite.git .
    fi

    # Verify the clone succeeded and show commit hash for auditability
    local commit_hash
    commit_hash=$(git rev-parse HEAD)
    log_info "Cloned at commit: $commit_hash"

    log_success "ZQLite source downloaded"
}

# Build ZQLite libraries
build_zqlite() {
    log_info "Building ZQLite libraries..."

    # Build ZQLite with Zig
    zig build

    # Verify the build artifacts exist
    if [ ! -f "zig-out/lib/libzqlite.a" ] || [ ! -f "zig-out/lib/libzqlite_c.a" ]; then
        log_error "ZQLite build failed - library files not found"
        exit 1
    fi

    if [ ! -f "include/zqlite.h" ]; then
        log_error "ZQLite header file not found"
        exit 1
    fi

    log_success "ZQLite libraries built successfully"
}

# Setup Ghostwire Rust project structure
setup_ghostwire() {
    log_info "Setting up Ghostwire project structure..."

    cd ..

    if [ ! -d "$GHOSTWIRE_DIR" ]; then
        mkdir -p "$GHOSTWIRE_DIR"
        cd "$GHOSTWIRE_DIR"

        # Initialize a new Cargo workspace
        log_info "Creating Cargo workspace..."
        cat > Cargo.toml << 'EOF'
[workspace]
members = ["zqlite-rs"]
resolver = "2"

[workspace.dependencies]
libc = "0.2"
thiserror = "1.0"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1.0", features = ["full"] }
tracing = "0.1"
uuid = { version = "1.0", features = ["v4"] }
tempfile = "3.0"
criterion = "0.5"
bindgen = "0.70"
cc = "1.0"
pkg-config = "0.3"
tokio-test = "0.4"
rustc-hash = "1.1"
EOF

        log_success "Cargo workspace created"
    else
        cd "$GHOSTWIRE_DIR"
        log_info "Using existing Ghostwire directory"
    fi
}

# Create zqlite-rs FFI bindings crate
create_zqlite_rs() {
    log_info "Creating zqlite-rs FFI bindings crate..."

    if [ ! -d "zqlite-rs" ]; then
        cargo new --lib zqlite-rs
    fi

    cd zqlite-rs

    # Create Cargo.toml for zqlite-rs
    cat > Cargo.toml << 'EOF'
[package]
name = "zqlite-rs"
version = "0.1.0"
edition = "2021"
authors = ["Ghostwire Team <team@ghostwire.dev>"]
description = "Rust bindings for ZQLite - High-performance embedded database with post-quantum cryptography"
license = "MIT OR Apache-2.0"
repository = "https://github.com/ghostkellz/zqlite"
keywords = ["database", "sql", "embedded", "post-quantum", "crypto"]
categories = ["database-implementations"]

[dependencies]
libc = { workspace = true }
thiserror = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
tokio = { workspace = true, optional = true }
tracing = { workspace = true }
uuid = { workspace = true }

[build-dependencies]
cc = "1.0"
bindgen = "0.70"
pkg-config = "0.3"

[features]
default = ["async"]
async = ["tokio"]
crypto = []
json = []
compression = []

[dev-dependencies]
tokio-test = "0.4"
tempfile = "3.0"
criterion = "0.5"
EOF

    # Create build.rs
    cat > build.rs << 'EOF'
use std::env;
use std::path::PathBuf;

fn main() {
    // Get the path to the ZQLite library
    let zqlite_dir = env::var("ZQLITE_DIR")
        .unwrap_or_else(|_| "../zqlite-ffi".to_string());

    // Build ZQLite C library
    let zqlite_lib_path = format!("{}/zig-out/lib", zqlite_dir);
    let zqlite_include_path = format!("{}/include", zqlite_dir);

    // Build the ZQLite library if it doesn't exist
    if !std::path::Path::new(&format!("{}/libzqlite_c.a", zqlite_lib_path)).exists() {
        println!("cargo:warning=Building ZQLite C library...");
        let output = std::process::Command::new("zig")
            .args(&["build"])
            .current_dir(&zqlite_dir)
            .output()
            .expect("Failed to build ZQLite");

        if !output.status.success() {
            panic!(
                "Failed to build ZQLite: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    // Link to the ZQLite library
    println!("cargo:rustc-link-search=native={}", zqlite_lib_path);
    println!("cargo:rustc-link-lib=static=zqlite_c");

    // Generate bindings
    let bindings = bindgen::Builder::default()
        .header(&format!("{}/zqlite.h", zqlite_include_path))
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .derive_debug(true)
        .derive_default(true)
        .derive_copy(true)
        .derive_eq(true)
        .derive_partialeq(true)
        .generate()
        .expect("Unable to generate bindings");

    // Write the bindings to src/bindings.rs
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");

    // Tell cargo to invalidate the built crate whenever the wrapper changes
    println!("cargo:rerun-if-changed={}/zqlite.h", zqlite_include_path);
    println!("cargo:rerun-if-changed={}", zqlite_dir);
}
EOF

    log_success "zqlite-rs crate created"
    cd ..
}

# Create example usage file
create_example() {
    log_info "Creating example usage file..."

    mkdir -p examples
    cat > examples/basic_usage.rs << 'EOF'
use zqlite_rs::{Connection, Result};

fn main() -> Result<()> {
    println!("ZQLite FFI Example");

    // Open an in-memory database
    let conn = Connection::open(":memory:")?;
    println!("Database opened successfully");

    // Create a test table
    conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")?;
    println!("Table created successfully");

    // Insert some test data
    conn.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")?;
    conn.execute("INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')")?;
    println!("Test data inserted");

    // Query data
    let rows = conn.query("SELECT id, name, email FROM users")?;
    println!("Query executed successfully");

    // Print ZQLite version
    println!("ZQLite version: {}", Connection::version());

    println!("Example completed successfully!");
    Ok(())
}
EOF

    # Add example to Cargo.toml
    cat >> zqlite-rs/Cargo.toml << 'EOF'

[[example]]
name = "basic_usage"
path = "../examples/basic_usage.rs"
EOF

    log_success "Example file created"
}

# Create README with instructions
create_readme() {
    log_info "Creating README with usage instructions..."

    cat > README.md << EOF
# ZQLite FFI for Ghostwire

This directory contains ZQLite with Rust FFI bindings for Ghostwire testing.

## Structure

\`\`\`
${GHOSTWIRE_DIR}/
├── Cargo.toml          # Workspace configuration
├── zqlite-rs/          # Rust FFI bindings for ZQLite
├── examples/           # Usage examples
└── README.md           # This file

${INSTALL_DIR}/
├── src/                # ZQLite source code
├── include/            # C headers
├── zig-out/lib/        # Built libraries
└── build.zig           # Zig build configuration
\`\`\`

## Usage

### Building

\`\`\`bash
cd ${GHOSTWIRE_DIR}
cargo build --release
\`\`\`

### Running Examples

\`\`\`bash
cd ${GHOSTWIRE_DIR}
cargo run --example basic_usage
\`\`\`

### Testing

\`\`\`bash
cd ${GHOSTWIRE_DIR}/zqlite-rs
cargo test
\`\`\`

## Environment Variables

- \`ZQLITE_DIR\`: Path to ZQLite source (default: \`../../${INSTALL_DIR}\`)

## Features

- \`async\`: Enable async/await support with Tokio (default)
- \`crypto\`: Enable cryptographic features
- \`json\`: Enable JSON support
- \`compression\`: Enable compression features

## Dependencies

- Zig compiler (${ZIG_VERSION})
- Rust toolchain
- Git

## Integration

To use zqlite-rs in your project:

\`\`\`toml
[dependencies]
zqlite-rs = { path = "path/to/zqlite-rs" }
\`\`\`

\`\`\`rust
use zqlite_rs::{Connection, Result};

fn main() -> Result<()> {
    let conn = Connection::open("database.db")?;
    conn.execute("CREATE TABLE test (id INTEGER, name TEXT)")?;
    // ... use the connection
    Ok(())
}
\`\`\`

## Troubleshooting

1. **Build failures**: Ensure Zig is installed and in PATH
2. **Linking errors**: Check that ZQLite libraries were built successfully
3. **Missing headers**: Verify \`include/zqlite.h\` exists in the ZQLite directory

## Generated by GhostwireInstall.sh

This setup was created by the GhostwireInstall.sh script for easy ZQLite FFI testing.
EOF

    log_success "README created"
}

# Build and test the setup
test_installation() {
    log_info "Testing the installation..."

    cd "$GHOSTWIRE_DIR"

    # Build the project
    log_info "Building Rust project..."
    if cargo build; then
        log_success "Build successful"
    else
        log_error "Build failed"
        exit 1
    fi

    # Run tests
    log_info "Running tests..."
    cd zqlite-rs
    if cargo test; then
        log_success "Tests passed"
    else
        log_warning "Some tests failed, but installation may still be usable"
    fi

    cd ..

    # Try to run the example
    log_info "Running example..."
    if cargo run --example basic_usage; then
        log_success "Example ran successfully"
    else
        log_warning "Example failed, but core functionality may still work"
    fi
}

# Main installation function
main() {
    log_info "Starting ZQLite FFI installation for Ghostwire testing..."
    log_info "Installation directory: $INSTALL_DIR"
    log_info "Ghostwire directory: $GHOSTWIRE_DIR"
    log_info "Zig version: $ZIG_VERSION"

    check_requirements
    install_zig
    download_zqlite
    build_zqlite
    setup_ghostwire
    create_zqlite_rs
    create_example
    create_readme

    log_success "ZQLite FFI installation completed!"
    log_info "To test the installation:"
    log_info "  cd $GHOSTWIRE_DIR"
    log_info "  cargo run --example basic_usage"
    log_info ""
    log_info "To use in your project, add to Cargo.toml:"
    log_info "  zqlite-rs = { path = \"$PWD/$GHOSTWIRE_DIR/zqlite-rs\" }"
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    test)
        test_installation
        ;;
    clean)
        log_info "Cleaning up installation directories..."
        rm -rf "$INSTALL_DIR" "$GHOSTWIRE_DIR"
        log_success "Cleanup completed"
        ;;
    *)
        echo "Usage: $0 [install|test|clean]"
        echo "  install: Full installation (default)"
        echo "  test: Test existing installation"
        echo "  clean: Remove installation directories"
        exit 1
        ;;
esac