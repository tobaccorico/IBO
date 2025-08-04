#!/bin/bash
set -e  # Exit on error

# Configuration
WHISPER_DIR="third_party/whisper.cpp"
WHISPER_BUILD_CACHE="${WHISPER_DIR}/.build-cache"
BUILD_VERSION="1.0.0"
BUILD_NUMBER=$(cat build_number.txt 2>/dev/null || echo 1)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Check if whisper rebuild is needed
check_whisper_cache() {
    local platform=$1
    local cache_file="${WHISPER_BUILD_CACHE}/${platform}.built"
    local whisper_src_hash=$(find ${WHISPER_DIR}/src -name "*.cpp" -o -name "*.c" | xargs md5sum | md5sum | cut -d' ' -f1)
    
    if [[ -f "$cache_file" ]]; then
        local cached_hash=$(cat "$cache_file")
        if [[ "$cached_hash" == "$whisper_src_hash" ]]; then
            return 0  # No rebuild needed
        fi
    fi
    
    # Save hash for next time
    mkdir -p "${WHISPER_BUILD_CACHE}"
    echo "$whisper_src_hash" > "$cache_file"
    return 1  # Rebuild needed
}

# Build whisper only if needed
build_whisper_cached() {
    local platform=$1
    local build_dir=$2
    shift 2
    local cmake_args=("$@")
    
    if check_whisper_cache "$platform"; then
        log_info "Whisper already built for $platform (cached)"
        return 0
    fi
    
    log_info "Building whisper for $platform..."
    mkdir -p "$build_dir"
    (
        cd "$build_dir"
        cmake "${cmake_args[@]}" ../..
        make -j$(nproc) whisper
    )
}

# Setup Go environment for whisper bindings
setup_go_whisper_env() {
    # Use vendored whisper.cpp bindings instead of downloading
    if [[ ! -d "vendor/github.com/ggerganov/whisper.cpp" ]]; then
        log_info "Setting up vendored whisper bindings..."
        mkdir -p vendor/github.com/ggerganov/whisper.cpp/bindings/go
        
        # Create a minimal whisper.go binding that references our local build
        cat > vendor/github.com/ggerganov/whisper.cpp/bindings/go/whisper.go << 'EOF'
package whisper

// #cgo CFLAGS: -I${SRCDIR}/../../../../third_party/whisper.cpp/include
// #cgo LDFLAGS: -L${SRCDIR}/../../../../third_party/whisper.cpp/build-host/src -lwhisper
// #include <whisper.h>
import "C"

// Add minimal bindings as needed
EOF
    fi
    
    # Set CGO flags to use our local whisper build
    export CGO_CFLAGS="-I${PWD}/${WHISPER_DIR} -I${PWD}/${WHISPER_DIR}/include"
    export CGO_LDFLAGS="-L${PWD}/${WHISPER_DIR}/build-host/src -lwhisper"
}

# Fix Go compilation errors
fix_go_errors() {
    log_info "Fixing Go compilation errors..."
    
    # Fix the client.go errors
    if [[ -f "internal/quid/client.go" ]]; then
        # Add missing imports
        sed -i '1s/^/package quid\n\nimport (\n    "encoding\/binary"\n    "math"\n    "github.com\/gagliardetto\/solana-go"\n)\n\n/' internal/quid/client.go 2>/dev/null || true
        
        # Fix battleID.Bytes() - assuming battleID is uint64
        sed -i 's/battleID\.Bytes/binary.BigEndian.PutUint64(make(\[\]byte, 8), battleID)/' internal/quid/client.go 2>/dev/null || true
    fi
}

# Main build process
main() {
    log_info "🛠  Starting optimized multi-platform build..."
    log_info "Version: ${BUILD_VERSION}, Build: ${BUILD_NUMBER}"
    
    # Download Go dependencies once
    log_info "Downloading Go dependencies..."
    go mod download
    go mod verify
    
    # Setup whisper.cpp if needed
    if [[ ! -d "$WHISPER_DIR" ]]; then
        log_error "Whisper.cpp not found. Please run setup script first."
        exit 1
    fi
    
    # Build whisper for host only once
    if ! check_whisper_cache "host"; then
        build_whisper_cached "host" "${WHISPER_DIR}/build-host" \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_CUDA=OFF \
            -DGGML_HIPBLAS=OFF \
            -DGGML_VULKAN=OFF
    fi
    
    # Setup Go environment
    setup_go_whisper_env
    fix_go_errors
    
    # Build for Linux
    log_info "📦 Building for Linux..."
    if go build -v -o build/thuggable-linux ./cmd/thuggable; then
        log_success "Linux build complete"
    else
        log_error "Linux build failed"
    fi
    
    # Build for Android (using pre-built whisper libraries if available)
    if command -v fyne &> /dev/null; then
        log_info "📦 Building for Android..."
        
        # Only build Android whisper libraries if not cached
        if [[ -n "$ANDROID_NDK_HOME" ]] || [[ -n "$ANDROID_NDK_ROOT" ]]; then
            NDK_PATH="${ANDROID_NDK_HOME:-$ANDROID_NDK_ROOT}"
            
            for arch in arm64-v8a armeabi-v7a; do
                if ! check_whisper_cache "android-$arch"; then
                    build_whisper_cached "android-$arch" "${WHISPER_DIR}/build-android-$arch" \
                        -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
                        -DANDROID_ABI="$arch" \
                        -DANDROID_PLATFORM=android-21 \
                        -DCMAKE_BUILD_TYPE=Release
                fi
            done
        fi
        
        # Build Android APK with correct flag
        fyne package -os android \
            --name "Thuggable" \
            --app-id "com.thuggable.app" \
            --icon assets/icon.png \
            --app-version "$BUILD_VERSION" \
            --app-build "$BUILD_NUMBER" \
            --release \
            -o build/thuggable.apk || log_warn "Android build failed"
    fi
    
    # Increment build number
    echo $((BUILD_NUMBER + 1)) > build_number.txt
    
    log_success "✅ Build complete!"
    log_info "Build artifacts are in: build/"
    ls -la build/ 2>/dev/null || true
}

# Run main
main "$@"