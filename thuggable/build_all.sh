#!/bin/bash
# ------------------------- #
# Multi-platform builder #
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

# Paths for whisper
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
IS_WINDOWS=false
IS_MAC=false
IS_LINUX=false
[[ "$OS" == "mingw"* || "$OS" == "cygwin"* || "$OS" == "msys"* ]] && IS_WINDOWS=true
[[ "$OS" == "darwin"* ]] && IS_MAC=true
[[ "$OS" == "linux"* ]] && IS_LINUX=true

# Detect Linux distribution
detect_linux_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_LIKE=$ID_LIKE
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    elif [ -f /etc/redhat-release ]; then
        DISTRO="rhel"
    else
        DISTRO="unknown"
    fi
}

# Install Linux dependencies
install_linux_dependencies() {
    log_info "Installing Linux dependencies..."
    
    detect_linux_distro
    
    # Check if running with sudo or as root
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        log_warn "This script needs sudo privileges to install dependencies."
        log_info "Please enter your password when prompted."
    fi
    
    case "$DISTRO" in
        ubuntu|debian|pop|mint)
            log_info "Detected Debian-based distribution: $DISTRO"
            
            # Update package list
            sudo apt-get update
            
            # Install build essentials and dependencies
            sudo apt-get install -y \
                build-essential \
                cmake \
                make \
                git \
                curl \
                wget \
                pkg-config \
                gcc \
                libgl1-mesa-dev \
                xorg-dev \
                libx11-dev \
                libxcursor-dev \
                libxrandr-dev \
                libxinerama-dev \
                libxi-dev \
                libxxf86vm-dev \
                libasound2-dev \
                libpulse-dev \
                libjack-dev \
                portaudio19-dev \
                libsqlite3-dev \
                sqlite3 \
                openjdk-11-jdk \
                android-tools-adb \
                android-tools-fastboot \
                autoconf \
                automake \
                libtool \
                tree
            
            # Install Go if not present
            if ! command -v go >/dev/null 2>&1; then
                log_info "Installing Go..."
                wget -q -O go.tar.gz https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
                sudo tar -C /usr/local -xzf go.tar.gz
                rm go.tar.gz
                echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                export PATH=$PATH:/usr/local/go/bin
            fi
            ;;
            
        fedora|rhel|centos)
            log_info "Detected Red Hat-based distribution: $DISTRO"
            
            sudo dnf install -y \
                gcc \
                gcc-c++ \
                make \
                cmake \
                git \
                curl \
                wget \
                pkg-config \
                mesa-libGL-devel \
                libX11-devel \
                libXcursor-devel \
                libXrandr-devel \
                libXinerama-devel \
                libXi-devel \
                libXxf86vm-devel \
                alsa-lib-devel \
                pulseaudio-libs-devel \
                jack-audio-connection-kit-devel \
                portaudio-devel \
                sqlite-devel \
                sqlite \
                java-11-openjdk-devel \
                autoconf \
                automake \
                libtool \
                tree
            
            # Install Go if not present
            if ! command -v go >/dev/null 2>&1; then
                log_info "Installing Go..."
                wget -q -O go.tar.gz https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
                sudo tar -C /usr/local -xzf go.tar.gz
                rm go.tar.gz
                echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                export PATH=$PATH:/usr/local/go/bin
            fi
            ;;
            
        arch|manjaro)
            log_info "Detected Arch-based distribution: $DISTRO"
            
            sudo pacman -Syu --noconfirm
            sudo pacman -S --noconfirm \
                base-devel \
                cmake \
                make \
                git \
                curl \
                wget \
                pkg-config \
                go \
                libgl \
                xorg-server-devel \
                libx11 \
                libxcursor \
                libxrandr \
                libxinerama \
                libxi \
                libxxf86vm \
                alsa-lib \
                pulseaudio \
                jack2 \
                portaudio \
                sqlite \
                jdk11-openjdk \
                tree
            ;;
            
        *)
            log_warn "Unknown distribution: $DISTRO"
            log_warn "Please install dependencies manually"
            ;;
    esac
    
    # Install fyne command if not present
    if ! command -v fyne >/dev/null 2>&1; then
        log_info "Installing fyne command..."
        go install fyne.io/fyne/v2/cmd/fyne@latest
        
        # Add Go bin to PATH if not already there
        if [[ ":$PATH:" != *":$HOME/go/bin:"* ]]; then
            echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc
            export PATH=$PATH:$HOME/go/bin
        fi
    fi
    
    # Download and setup Android SDK/NDK if not present
    if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ]; then
        log_info "Setting up Android SDK/NDK..."
        
        # Create android directory
        mkdir -p ~/android-sdk
        cd ~/android-sdk
        
        # Download command line tools
        if [ ! -d "cmdline-tools" ]; then
            wget -q https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip
            unzip -q commandlinetools-linux-9477386_latest.zip
            mkdir -p cmdline-tools/latest
            mv cmdline-tools/* cmdline-tools/latest/ 2>/dev/null || true
            rm commandlinetools-linux-9477386_latest.zip
        fi
        
        # Set up environment
        export ANDROID_HOME=~/android-sdk
        export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
        export PATH=$PATH:$ANDROID_HOME/platform-tools
        
        # Accept licenses and install NDK
        yes | sdkmanager --licenses >/dev/null 2>&1 || true
        sdkmanager "platform-tools" "platforms;android-30" "ndk;25.2.9519653"
        
        # Set NDK path
        export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/25.2.9519653
        
        # Add to bashrc
        echo 'export ANDROID_HOME=~/android-sdk' >> ~/.bashrc
        echo 'export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/25.2.9519653' >> ~/.bashrc
        echo 'export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin' >> ~/.bashrc
        echo 'export PATH=$PATH:$ANDROID_HOME/platform-tools' >> ~/.bashrc
        
        cd - >/dev/null
        
        log_info "Android SDK/NDK setup complete"
    fi
}

# Check for required tools
check_requirements() {
    log_info "Checking build requirements..."
    
    local missing=()
    command -v cmake >/dev/null 2>&1 || missing+=("cmake")
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v go >/dev/null 2>&1 || missing+=("go")
    command -v fyne >/dev/null 2>&1 || missing+=("fyne")
    command -v gcc >/dev/null 2>&1 || missing+=("gcc")
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_warn "Missing required tools: ${missing[*]}"
        
        if $IS_LINUX; then
            log_info "Attempting to install missing dependencies..."
            install_linux_dependencies
            
            # Re-check after installation
            missing=()
            command -v cmake >/dev/null 2>&1 || missing+=("cmake")
            command -v make >/dev/null 2>&1 || missing+=("make")
            command -v go >/dev/null 2>&1 || missing+=("go")
            command -v fyne >/dev/null 2>&1 || missing+=("fyne")
            
            if [ ${#missing[@]} -ne 0 ]; then
                log_error "Still missing tools after installation: ${missing[*]}"
                exit 1
            fi
        else
            log_error "Please install missing tools and try again"
            exit 1
        fi
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

# Start
log_info "🛠  Starting multi-platform build..."

# Check requirements (will auto-install on Linux)
check_requirements

# Setup whisper.cpp
setup_whisper
download_whisper_model

# Build whisper for host first (needed for CGO)
build_whisper_host

# Prepare Go environment
prepare_go_modules

# Android build
if [ -n "${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT}}" ]; then
    log_info "📦 Building for Android..."
    
    # Build whisper for Android first
    build_whisper_android || log_warn "Whisper Android build failed, continuing..."
    
    # Set Android-specific environment
    export CGO_ENABLED=1
    export CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
    
    run_or_exit fyne package --target android --name "${APP_NAME}.apk" --app-id "${APP_ID}" --icon "${ICON_FILE}" --app-version "${VERSION}" --app-build "${BUILD}"
else
    log_warn "Skipping Android build - NDK not found"
fi

# Web build
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
    run_or_exit fyne package --target ios --name "${APP_NAME}.app" --app-id "${APP_ID}" --icon "${ICON_FILE}"
    
    log_info "📦 Building for macOS..."
    run_or_exit fyne package --target darwin --name "${APP_NAME}.app" --app-id "${APP_ID}" --icon "${ICON_FILE}"
    
    log_info "📦 Building for iOS Simulator..."
    run_or_exit fyne package --target iossimulator --app-id "${APP_ID}" --icon "${ICON_FILE}"
else
    log_info "⚠️ Skipping iOS/macOS builds — not on macOS"
fi

# Windows — only if on Windows
if $IS_WINDOWS; then
    log_info "📦 Building for Windows..."
    build_whisper_windows || log_warn "Whisper Windows build failed, continuing..."
    run_or_exit fyne package --target windows --name "${APP_NAME}.exe" --app-id "${APP_ID}" --icon "${ICON_FILE}"
else
    log_info "⚠️ Skipping Windows build — not on Windows"
fi

# Android release packaging
if [ -n "${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT}}" ]; then
    log_info "🚀 Packaging release for Android..."
    run_or_exit fyne release --target android --name "${APP_NAME}.apk" --app-id "${APP_ID}" --icon "${ICON_FILE}" --app-version "${VERSION}" --app-build "${BUILD}" --category "${CATEGORY}"
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
log_info "🗂 Snapshotting folder structure (3 levels deep)..."
tree -L 3 internal go.mod go.sum main.go > folders.txt 2>/dev/null || true

log_info "✅ Build complete."
