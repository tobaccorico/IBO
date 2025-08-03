#!/bin/bash

# Build script for Thuggable multi-platform application
# This script builds the Go application for multiple platforms including Android

set -e  # Exit on error

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Version configuration
# Read version from version file or use default
if [ -f "version.txt" ]; then
    APP_VERSION=$(cat version.txt | tr -d '\n' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "1.0.0")
else
    APP_VERSION="1.0.0"
fi

# Build number - can be from CI/CD or local counter
if [ -f "build_number.txt" ]; then
    APP_BUILD=$(cat build_number.txt | tr -d '\n')
    # Increment for next build
    echo $((APP_BUILD + 1)) > build_number.txt
else
    APP_BUILD="1"
    echo "2" > build_number.txt
fi

# Application configuration
APP_NAME="Thuggable"
APP_ID="com.thuggable.app"
ICON_PATH="icon.png"

# Whisper configuration
WHISPER_MODEL="base.en"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin"

# Build configuration
BUILD_DIR="build"
THIRD_PARTY_DIR="third_party"
WHISPER_DIR="${THIRD_PARTY_DIR}/whisper.cpp"

# Android configuration
ANDROID_MIN_SDK=21
ANDROID_TARGET_SDK=33
ANDROID_ARCHS=("armeabi-v7a" "arm64-v8a" "x86" "x86_64")

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

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Utility functions
command_exists() {
    command -v "$1" &> /dev/null
}

get_os() {
    case "$OSTYPE" in
        linux*)   echo "linux" ;;
        darwin*)  echo "darwin" ;;
        msys*)    echo "windows" ;;
        cygwin*)  echo "windows" ;;
        *)        echo "unknown" ;;
    esac
}

get_arch() {
    case "$(uname -m)" in
        x86_64)   echo "amd64" ;;
        i686)     echo "386" ;;
        armv7l)   echo "arm" ;;
        aarch64)  echo "arm64" ;;
        *)        echo "unknown" ;;
    esac
}

# Dependency checking and installation
check_dependencies() {
    log_info "Checking build requirements..."
    
    local missing_deps=()
    local missing_go_tools=()
    
    # Essential tools
    local essential_tools=("go" "git" "make" "gcc" "cmake")
    for tool in "${essential_tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_deps+=("$tool")
        fi
    done
    
    # Android specific
    if [ -z "$ANDROID_HOME" ] && [ -z "$ANDROID_SDK_ROOT" ]; then
        log_warn "Android SDK not found (ANDROID_HOME or ANDROID_SDK_ROOT not set)"
        missing_deps+=("android-sdk")
    fi
    
    if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ] && [ -z "$NDK_HOME" ]; then
        log_warn "Android NDK not found (ANDROID_NDK_HOME, ANDROID_NDK_ROOT, or NDK_HOME not set)"
        missing_deps+=("android-ndk")
    fi
    
    # Go tools
    if ! command_exists "fyne"; then
        missing_go_tools+=("fyne.io/fyne/v2/cmd/fyne@latest")
    fi
    
    # Platform specific
    local os=$(get_os)
    case "$os" in
        linux)
            # Check for required libraries
            local required_libs=("libgl1-mesa-dev" "xorg-dev" "libxcursor-dev" "libxrandr-dev" "libxinerama-dev" "libxi-dev")
            ;;
        darwin)
            # macOS specific checks
            if ! command_exists "brew"; then
                missing_deps+=("homebrew")
            fi
            ;;
    esac
    
    # Report findings
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install missing dependencies and try again"
        
        # Provide installation hints
        case "$os" in
            linux)
                if [ -f /etc/debian_version ]; then
                    log_info "On Debian/Ubuntu, you can install with:"
                    log_info "sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}"
                elif [ -f /etc/redhat-release ]; then
                    log_info "On RHEL/CentOS/Fedora, you can install with:"
                    log_info "sudo yum install -y ${missing_deps[*]}"
                fi
                ;;
            darwin)
                log_info "On macOS, you can install with Homebrew:"
                log_info "brew install ${missing_deps[*]}"
                ;;
        esac
        
        return 1
    fi
    
    # Install Go tools if needed
    if [ ${#missing_go_tools[@]} -ne 0 ]; then
        log_info "Installing required Go tools..."
        for tool in "${missing_go_tools[@]}"; do
            log_info "Installing $tool..."
            go install "$tool" || {
                log_error "Failed to install $tool"
                return 1
            }
        done
    fi
    
    log_success "All dependencies satisfied"
    return 0
}

# Find Android NDK
find_android_ndk() {
    # Check various NDK environment variables
    local ndk_paths=()
    
    [ -n "$ANDROID_NDK_HOME" ] && ndk_paths+=("$ANDROID_NDK_HOME")
    [ -n "$ANDROID_NDK_ROOT" ] && ndk_paths+=("$ANDROID_NDK_ROOT")
    [ -n "$NDK_HOME" ] && ndk_paths+=("$NDK_HOME")
    
    # Check common locations
    if [ -n "$ANDROID_HOME" ]; then
        # Look for NDK in Android SDK
        if [ -d "$ANDROID_HOME/ndk" ]; then
            # Find the latest NDK version
            local latest_ndk=$(ls -1 "$ANDROID_HOME/ndk" 2>/dev/null | sort -V | tail -1)
            [ -n "$latest_ndk" ] && ndk_paths+=("$ANDROID_HOME/ndk/$latest_ndk")
        fi
        
        # Legacy location
        [ -d "$ANDROID_HOME/ndk-bundle" ] && ndk_paths+=("$ANDROID_HOME/ndk-bundle")
    fi
    
    # Find first valid NDK
    for ndk in "${ndk_paths[@]}"; do
        if [ -f "$ndk/build/cmake/android.toolchain.cmake" ]; then
            echo "$ndk"
            return 0
        fi
    done
    
    return 1
}

# Setup whisper.cpp
setup_whisper() {
    log_info "Setting up whisper.cpp..."
    
    # Create third party directory
    mkdir -p "$THIRD_PARTY_DIR"
    
    # Clone or update whisper.cpp
    if [ ! -d "$WHISPER_DIR" ]; then
        log_info "Cloning whisper.cpp..."
        git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
    else
        log_info "Updating whisper.cpp..."
        cd "$WHISPER_DIR"
        git pull origin master
        cd - > /dev/null
    fi
    
    # Download model if needed
    local model_dir="$WHISPER_DIR/models"
    local model_path="$model_dir/ggml-${WHISPER_MODEL}.bin"
    
    if [ ! -f "$model_path" ]; then
        log_info "Downloading whisper ${WHISPER_MODEL} model..."
        mkdir -p "$model_dir"
        
        if command_exists "wget"; then
            wget -O "$model_path" "$WHISPER_MODEL_URL" || {
                log_error "Failed to download model"
                return 1
            }
        elif command_exists "curl"; then
            curl -L -o "$model_path" "$WHISPER_MODEL_URL" || {
                log_error "Failed to download model"
                return 1
            }
        else
            log_error "Neither wget nor curl found. Cannot download model."
            return 1
        fi
    else
        log_info "Whisper model already downloaded"
    fi
    
    return 0
}

# Build whisper.cpp for host
build_whisper_host() {
    log_info "Building whisper.cpp for host platform..."
    
    cd "$WHISPER_DIR"
    
    # Clean previous build
    rm -rf build-host
    mkdir -p build-host
    cd build-host
    
    # Configure
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_BUILD_EXAMPLES=ON \
        -DWHISPER_BUILD_TESTS=OFF || {
        log_error "Failed to configure whisper.cpp"
        return 1
    }
    
    # Build
    make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1) || {
        log_error "Failed to build whisper.cpp"
        return 1
    }
    
    cd "$SCRIPT_DIR"
    log_success "Whisper host build complete"
    return 0
}

# Build whisper.cpp for Android
build_whisper_android() {
    log_info "Building whisper.cpp for Android..."
    
    # Find NDK
    local ndk_path=$(find_android_ndk)
    if [ -z "$ndk_path" ]; then
        log_error "Cannot find Android NDK"
        return 1
    fi
    
    log_info "Using Android NDK: $ndk_path"
    
    cd "$WHISPER_DIR"
    
    # Build for each architecture
    for arch in "${ANDROID_ARCHS[@]}"; do
        log_info "Building for Android $arch..."
        
        # Clean previous build
        rm -rf "build-android-$arch"
        mkdir -p "build-android-$arch"
        cd "build-android-$arch"
        
        # Configure
        cmake .. \
            -DCMAKE_TOOLCHAIN_FILE="$ndk_path/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI=$arch \
            -DANDROID_PLATFORM=android-${ANDROID_MIN_SDK} \
            -DCMAKE_BUILD_TYPE=Release \
            -DWHISPER_BUILD_EXAMPLES=OFF \
            -DWHISPER_BUILD_TESTS=OFF || {
            log_error "Failed to configure whisper.cpp for $arch"
            cd ..
            continue
        }
        
        # Build
        make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1) || {
            log_error "Failed to build whisper.cpp for $arch"
            cd ..
            continue
        }
        
        cd ..
    done
    
    cd "$SCRIPT_DIR"
    log_success "Whisper Android build complete"
    return 0
}

# Fix for whisper.cpp Go bindings
# Fix for whisper.cpp Go bindings
setup_whisper_go_bindings() {
    log_info "Setting up whisper.cpp Go bindings..."
    
    # First, let's find where whisper.h actually is
    log_info "Searching for whisper.h..."
    local whisper_header_locations=$(find "${WHISPER_DIR}" -name "whisper.h" -type f 2>/dev/null)
    
    if [ -z "$whisper_header_locations" ]; then
        log_error "whisper.h not found in ${WHISPER_DIR}"
        log_info "Contents of whisper.cpp directory:"
        ls -la "${WHISPER_DIR}/"
        log_info "Looking in subdirectories..."
        find "${WHISPER_DIR}" -type d -name include
        find "${WHISPER_DIR}" -type d -name src
        return 1
    fi
    
    log_info "Found whisper.h at:"
    echo "$whisper_header_locations"
    
    # Get the first location
    local whisper_header=$(echo "$whisper_header_locations" | head -n1)
    local whisper_include_dir=$(dirname "$whisper_header")
    
    # The whisper.cpp bindings expect the header in the root or include directory
    # Let's check if we need to copy it
    if [ ! -f "${WHISPER_DIR}/whisper.h" ]; then
        log_info "Copying whisper.h to root directory..."
        cp "$whisper_header" "${WHISPER_DIR}/" || {
            log_error "Failed to copy whisper.h"
            return 1
        }
    fi
    
    # Also check common locations
    if [ -f "${WHISPER_DIR}/src/whisper.h" ] && [ ! -f "${WHISPER_DIR}/include/whisper.h" ]; then
        mkdir -p "${WHISPER_DIR}/include"
        cp "${WHISPER_DIR}/src/whisper.h" "${WHISPER_DIR}/include/"
    fi
    
    # Set CGO flags with multiple include paths
    export CGO_CFLAGS="-I${WHISPER_DIR} -I${WHISPER_DIR}/include -I${WHISPER_DIR}/src -I${whisper_include_dir}"
    export CGO_LDFLAGS="-L${WHISPER_DIR}/build-host -lwhisper"
    
    # Also check for the compiled library
    log_info "Checking for libwhisper.so..."
    local lib_locations=$(find "${WHISPER_DIR}" -name "libwhisper*" -type f 2>/dev/null)
    if [ -n "$lib_locations" ]; then
        log_info "Found whisper libraries at:"
        echo "$lib_locations"
        
        # Add all library paths
        local lib_paths=""
        while IFS= read -r lib_path; do
            local lib_dir=$(dirname "$lib_path")
            lib_paths="$lib_paths -L$lib_dir"
        done <<< "$lib_locations"
        
        export CGO_LDFLAGS="$lib_paths -lwhisper"
    fi
    
    # Set library paths
    export LD_LIBRARY_PATH="${WHISPER_DIR}/build-host:${LD_LIBRARY_PATH}"
    export DYLD_LIBRARY_PATH="${WHISPER_DIR}/build-host:${DYLD_LIBRARY_PATH}"
    
    # For Go modules
    export WHISPER_CPP_PATH="${WHISPER_DIR}"
    
    log_info "Whisper Go bindings configured"
    log_info "CGO_CFLAGS: $CGO_CFLAGS"
    log_info "CGO_LDFLAGS: $CGO_LDFLAGS"
    
    return 0
}

# Build Go application
build_go_app() {
    local platform=$1
    local output_dir="$BUILD_DIR/$platform"
    
    log_info "Building Go application for $platform..."
    
    # Setup whisper bindings
    setup_whisper_go_bindings || {
        log_error "Failed to setup whisper Go bindings"
        return 1
    }
    
    # Create output directory
    mkdir -p "$output_dir"
    
    case "$platform" in
        linux)
            # Build with proper tags and CGO settings
            CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
                go build -tags whisper \
                -ldflags "-L${WHISPER_DIR}/build-host -lwhisper" \
                -o "$output_dir/${APP_NAME}" . || {
                log_error "Failed to build for Linux"
                
                # Debug information
                log_info "Debugging build failure..."
                log_info "WHISPER_DIR: $WHISPER_DIR"
                log_info "Looking for libwhisper.so:"
                find "${WHISPER_DIR}" -name "libwhisper*" -type f
                
                return 1
            }
            log_success "Linux build complete: $output_dir/${APP_NAME}"
            ;;
            
        windows)
            # Check for MinGW
            if command_exists "x86_64-w64-mingw32-gcc"; then
                CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc \
                    go build -tags whisper \
                    -ldflags "-L${WHISPER_DIR}/build-host -lwhisper" \
                    -o "$output_dir/${APP_NAME}.exe" . || {
                    log_error "Failed to build for Windows"
                    return 1
                }
                log_success "Windows build complete: $output_dir/${APP_NAME}.exe"
            else
                log_warn "MinGW not found, skipping Windows build"
            fi
            ;;
            
        darwin)
            if [ "$(get_os)" = "darwin" ]; then
                CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 \
                    go build -tags whisper \
                    -ldflags "-L${WHISPER_DIR}/build-host -lwhisper" \
                    -o "$output_dir/${APP_NAME}" . || {
                    log_error "Failed to build for macOS"
                    return 1
                }
                log_success "macOS build complete: $output_dir/${APP_NAME}"
            else
                log_warn "Cross-compilation to macOS not supported from $(get_os)"
            fi
            ;;
            
        android)
            # Ensure we're in the correct directory
            cd "$SCRIPT_DIR"
            
            # Validate version format
            if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log_error "Invalid version format: $APP_VERSION"
                log_info "Version must be in format X.Y.Z where X, Y, and Z are integers"
                return 1
            fi
            
            # Build APK using fyne
            fyne package \
                --target android \
                --name "${APP_NAME}.apk" \
                --appID "$APP_ID" \
                --icon "$ICON_PATH" \
                --appVersion "$APP_VERSION" \
                --appBuild "$APP_BUILD" || {
                log_error "Failed to build Android APK"
                return 1
            }
            
            # Move APK to output directory
            mv "${APP_NAME}.apk" "$output_dir/" || {
                log_error "Failed to move APK to output directory"
                return 1
            }
            
            log_success "Android build complete: $output_dir/${APP_NAME}.apk"
            ;;
            
        *)
            log_error "Unknown platform: $platform"
            return 1
            ;;
    esac
    
    return 0
}

# Main build process
main() {
    log_info "🛠  Starting multi-platform build..."
    log_info "Version: $APP_VERSION, Build: $APP_BUILD"
    
    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi
    
    # Setup Go environment
    export PATH="$PATH:$(go env GOPATH)/bin"
    
    # Download Go dependencies
    log_info "Downloading Go dependencies..."
    go mod download || {
        log_error "Failed to download Go dependencies"
        exit 1
    }
    
    # Verify Go modules
    go mod verify || {
        log_error "Failed to verify Go modules"
        exit 1
    }
    
    # Setup whisper.cpp
    if ! setup_whisper; then
        exit 1
    fi
    
    # Build whisper.cpp for host
    if ! build_whisper_host; then
        exit 1
    fi
    
    # Create build directory
    mkdir -p "$BUILD_DIR"
    
    # Build for each platform
    local platforms=()
    local os=$(get_os)
    
    # Always build for current platform
    case "$os" in
        linux)   platforms+=("linux") ;;
        darwin)  platforms+=("darwin") ;;
        windows) platforms+=("windows") ;;
    esac
    
    # Add cross-compilation targets if available
    if [ "$os" = "linux" ]; then
        # Can build for Windows if MinGW is available
        command_exists "x86_64-w64-mingw32-gcc" && platforms+=("windows")
        
        # Can build for Android if SDK/NDK is available
        if [ -n "$ANDROID_HOME" ] || [ -n "$ANDROID_SDK_ROOT" ]; then
            if find_android_ndk > /dev/null; then
                platforms+=("android")
            fi
        fi
    fi
    
    # Build for each platform
    for platform in "${platforms[@]}"; do
        log_info "📦 Building for $platform..."
        
        # Build whisper.cpp for Android if needed
        if [ "$platform" = "android" ]; then
            if ! build_whisper_android; then
                log_warn "Failed to build whisper.cpp for Android, skipping Android build"
                continue
            fi
        fi
        
        # Build Go application
        if ! build_go_app "$platform"; then
            log_warn "Failed to build for $platform"
            continue
        fi
    done
    
    # Summary
    log_success "✅ Build complete!"
    log_info "Build artifacts are in: $BUILD_DIR/"
    
    # List built artifacts
    if [ -d "$BUILD_DIR" ]; then
        log_info "Built artifacts:"
        find "$BUILD_DIR" -type f -name "${APP_NAME}*" | while read -r file; do
            log_info "  - $file"
        done
    fi
    
    return 0
}

# Run main function
main "$@"