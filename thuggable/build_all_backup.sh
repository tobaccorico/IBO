
#!/bin/bash
# ------------------------- #
# Multi-platform builder     #
# ------------------------- #

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Metadata
APP_NAME="Thuggable"
APP_ID="com.thuggable.app"
ICON_FILE="icon.png"
VERSION="1.0"
BUILD="1"
CATEGORY="utilities"
SRC_DIR="."

# Paths
WHISPER_DIR="./third_party/whisper.cpp"
WHISPER_REPO="https://github.com/ggerganov/whisper.cpp.git"
MODELS_DIR="./models"

# Logger functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

run_or_exit() {
    "$@" 2>&1 || { log_error "Command failed: $*"; exit 1; }
}

# Platform detection
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
IS_WINDOWS=false
IS_MAC=false
IS_LINUX=false

case "$OS" in
    mingw*|cygwin*|msys*) IS_WINDOWS=true ;;
    darwin*) IS_MAC=true ;;
    linux*) IS_LINUX=true ;;
esac

# Check for required tools
check_requirements() {
    log_info "Checking build requirements..."
    
    local missing=()
    command -v cmake >/dev/null 2>&1 || missing+=("cmake")
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v go >/dev/null 2>&1 || missing+=("go")
    command -v fyne >/dev/null 2>&1 || missing+=("fyne")
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Please install missing tools and try again"
        exit 1
    fi
    
    # Check for Android NDK if building for Android
    if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ]; then
        log_warn "Android NDK not found. Android builds may fail."
        log_warn "Set ANDROID_NDK_HOME or ANDROID_NDK_ROOT environment variable"
    fi
}

# Download whisper model if not present
download_whisper_model() {
    log_info "Checking for whisper model..."
    mkdir -p "$MODELS_DIR"
    
    if [ ! -f "$MODELS_DIR/ggml-base.en.bin" ]; then
        log_info "Downloading whisper base.en model..."
        run_or_exit curl -L -o "$MODELS_DIR/ggml-base.en.bin" \
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
    else
        log_info "Whisper model already present"
    fi
}

# Clone or update whisper.cpp
setup_whisper() {
    log_info "Setting up whisper.cpp..."
    
    if [ -d "$WHISPER_DIR" ]; then
        log_info "Updating existing whisper.cpp..."
        cd "$WHISPER_DIR" && git pull && cd - >/dev/null
    else
        log_info "Cloning whisper.cpp..."
        run_or_exit git clone "$WHISPER_REPO" "$WHISPER_DIR"
    fi
}

# Build whisper for host platform (needed for CGO)
build_whisper_host() {
    log_info "Building whisper.cpp for host platform..."
    
    cd "$WHISPER_DIR" || exit 1
    mkdir -p build-host
    cd build-host || exit 1
    
    run_or_exit cmake ..
    run_or_exit make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    
    cd ../../.. || exit 1
    
    # Export paths for Go
    export CGO_CFLAGS="-I$(pwd)/$WHISPER_DIR"
    export CGO_LDFLAGS="-L$(pwd)/$WHISPER_DIR/build-host"
    
    log_info "Whisper host build complete"
}

# Build whisper for Android
build_whisper_android() {
    log_info "Building whisper.cpp for Android..."
    
    # Check for Android NDK
    NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT}}"
    if [ -z "$NDK_PATH" ]; then
        log_error "Android NDK not found. Please set ANDROID_NDK_HOME"
        return 1
    fi
    
    cd "$WHISPER_DIR" || exit 1
    
    # Build for multiple Android architectures
    for ABI in "armeabi-v7a" "arm64-v8a" "x86" "x86_64"; do
        log_info "Building for Android $ABI..."
        
        mkdir -p "build-android-$ABI"
        cd "build-android-$ABI" || exit 1
        
        run_or_exit cmake \
            -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI="$ABI" \
            -DANDROID_PLATFORM=android-21 \
            -DCMAKE_BUILD_TYPE=Release \
            -DWHISPER_BUILD_TESTS=OFF \
            -DWHISPER_BUILD_EXAMPLES=OFF \
            ..
        
        run_or_exit make -j$(nproc 2>/dev/null || echo 4)
        
        cd .. || exit 1
    done
    
    cd ../.. || exit 1
    
    # Create Android library structure
    mkdir -p android/libs
    cp "$WHISPER_DIR"/build-android-*/libwhisper.so android/libs/ 2>/dev/null || true
    
    log_info "Whisper Android build complete"
}

# Build whisper for iOS
build_whisper_ios() {
    log_info "Building whisper.cpp for iOS..."
    
    cd "$WHISPER_DIR" || exit 1
    
    # Use the iOS build script if available
    if [ -f "build-ios.sh" ]; then
        run_or_exit ./build-ios.sh
    else
        # Manual iOS build
        mkdir -p build-ios
        cd build-ios || exit 1
        
        run_or_exit cmake \
            -DCMAKE_TOOLCHAIN_FILE=../cmake/ios.toolchain.cmake \
            -DPLATFORM=OS64 \
            -DCMAKE_BUILD_TYPE=Release \
            -DWHISPER_BUILD_TESTS=OFF \
            -DWHISPER_BUILD_EXAMPLES=OFF \
            ..
        
        run_or_exit make -j$(sysctl -n hw.ncpu)
        
        cd .. || exit 1
    fi
    
    cd ../.. || exit 1
    log_info "Whisper iOS build complete"
}

# Build whisper for Windows
build_whisper_windows() {
    log_info "Building whisper.cpp for Windows..."
    
    cd "$WHISPER_DIR" || exit 1
    mkdir -p build-windows
    cd build-windows || exit 1
    
    # Use MinGW or MSVC depending on what's available
    if command -v mingw32-make >/dev/null 2>&1; then
        run_or_exit cmake -G "MinGW Makefiles" ..
        run_or_exit mingw32-make -j$(nproc 2>/dev/null || echo 4)
    else
        run_or_exit cmake ..
        run_or_exit cmake --build . --config Release
    fi
    
    cd ../../.. || exit 1
    log_info "Whisper Windows build complete"
}

# Prepare Go modules
prepare_go_modules() {
    log_info "Preparing Go modules..."
    
    # Add missing dependencies
    run_or_exit go get github.com/gen2brain/malgo
    run_or_exit go get github.com/ggerganov/whisper.cpp/bindings/go/pkg/whisper
    run_or_exit go get github.com/kkdai/youtube/v2
    run_or_exit go get github.com/mattn/go-sqlite3
    
    # Tidy modules
    run_or_exit go mod tidy
}

# Create build tags for conditional compilation
create_build_tags() {
    log_info "Setting up build tags..."
    
    # Create a build config file
    cat > build_config.go << 'EOF'
// +build !nobuild

package main

import (
    _ "thuggable-go/internal/transcription"
)
EOF
}

# Main build process
main() {
    log_info "🛠  Starting multi-platform build..."
    
    # Check requirements
    check_requirements
    
    # Setup whisper.cpp
    setup_whisper
    download_whisper_model
    
    # Build whisper for host first (needed for CGO)
    build_whisper_host
    
    # Prepare Go environment
    prepare_go_modules
    create_build_tags
    
    # Android build
    if [ -n "${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT}}" ]; then
        log_info "📦 Building for Android..."
        
        # Build whisper for Android first
        build_whisper_android || log_warn "Whisper Android build failed, continuing..."
        
        # Set Android-specific environment
        export CGO_ENABLED=1
        export CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
        
        run_or_exit fyne package --target android \
            --name "${APP_NAME}.apk" \
            --app-id "${APP_ID}" \
            --icon "${ICON_FILE}" \
            --app-version "${VERSION}" \
            --app-build "${BUILD}"
    else
        log_warn "Skipping Android build - NDK not found"
    fi
    
    # Web build (whisper not supported in WASM yet)
    log_info "📦 Building for Web..."
    export CGO_ENABLED=0  # Disable CGO for web
    run_or_exit fyne package --target web --app-id "${APP_ID}" --icon "${ICON_FILE}"
    export CGO_ENABLED=1  # Re-enable CGO
    
    # Start local server
    log_info "🌐 Serving WebAssembly (WASM) app on http://localhost:8080 ..."
    fyne serve "$SRC_DIR/wasm" &
    
    # iOS/macOS — skip if not macOS
    if $IS_MAC; then
        log_info "📦 Building for iOS..."
        build_whisper_ios || log_warn "Whisper iOS build failed, continuing..."
        run_or_exit fyne package --target ios \
            --name "${APP_NAME}.app" \
            --app-id "${APP_ID}" \
            --icon "${ICON_FILE}"
        
        log_info "📦 Building for macOS..."
        run_or_exit fyne package --target darwin \
            --name "${APP_NAME}.app" \
            --app-id "${APP_ID}" \
            --icon "${ICON_FILE}"
        
        log_info "📦 Building for iOS Simulator..."
        run_or_exit fyne package --target iossimulator \
            --app-id "${APP_ID}" \
            --icon "${ICON_FILE}"
    else
        log_info "⚠️  Skipping iOS/macOS builds — not on macOS"
    fi
    
    # Windows — only if on Windows
    if $IS_WINDOWS; then
        log_info "📦 Building for Windows..."
        build_whisper_windows || log_warn "Whisper Windows build failed, continuing..."
        run_or_exit fyne package --target windows \
            --name "${APP_NAME}.exe" \
            --app-id "${APP_ID}" \
            --icon "${ICON_FILE}"
    else
        log_info "⚠️  Skipping Windows build — not on Windows"
    fi
    
    # Android release packaging
    if [ -n "${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT}}" ]; then
        log_info "🚀 Packaging release for Android..."
        run_or_exit fyne release --target android \
            --name "${APP_NAME}.apk" \
            --app-id "${APP_ID}" \
            --icon "${ICON_FILE}" \
            --app-version "${VERSION}" \
            --app-build "${BUILD}" \
            --category "${CATEGORY}"
    fi
    
    # Copy whisper models to output directories
    log_info "📁 Copying whisper models to build outputs..."
    for dir in *.app *.apk wasm; do
        if [ -e "$dir" ]; then
            mkdir -p "$dir/models"
            cp -r "$MODELS_DIR"/* "$dir/models/" 2>/dev/null || true
        fi
    done
    
    # Tree snapshot (optional)
    log_info "🗂  Snapshotting folder structure (3 levels deep)..."
    tree -L 3 internal go.mod go.sum main.go > folders.txt 2>/dev/null || true
    
    log_info "✅ Build complete."
}

# Run main
main "$@"
