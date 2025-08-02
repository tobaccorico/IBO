
#!/bin/bash
set -e

echo "🛠  Starting Fyne multi-target build..."

# Check platform
OS=$(uname)

# Android build
echo "📦 Building for Android..."
fyne package -os android -name Thuggable.apk -appID com.thuggable.app -icon icon.png

# macOS and iOS only on Darwin (macOS)
if [ "$OS" == "Darwin" ]; then
    echo "📦 Building for macOS..."
    fyne package -os darwin -name Thuggable.app -appID com.thuggable.app -icon icon.png

    echo "📦 Building for iOS Simulator..."
    fyne package -os iossimulator -appID com.thuggable.app -icon icon.png

    echo "📦 Building for iOS..."
    fyne package -os ios -name Thuggable.app -appID com.thuggable.app -icon icon.png
else
    echo "⚠️  Skipping iOS/macOS targets (not supported on this platform)"
fi

# Windows only if on Windows
if [[ "$OS" == "MINGW"* || "$OS" == "CYGWIN"* || "$OS" == "MSYS"* || "$OS" == "Windows_NT" ]]; then
    echo "📦 Building for Windows..."
    fyne package -os windows -name Thuggable.exe -appID com.thuggable.app -icon icon.png
else
    echo "⚠️  Skipping Windows target (not supported on this platform)"
fi

# Web build
echo "📦 Building for Web..."
fyne package -os web -appID com.thuggable.app -icon icon.png

# Serve web build locally
echo "🌐 Serving web app on http://localhost:8080 ..."
fyne serve &

# 📝 Manual instructions for WASM deployment (still shown as comments)
echo
echo "📋 To deploy WASM manually:"
echo "    cp -r wasm/* /path/to/thuggable-web"
echo "    cd /path/to/thuggable-web && git push"

# Tree summary
tree -L 3 internal go.mod go.sum main.go > folders.txt

echo "✅ Build script complete."
