#!/bin/zsh
# Builds FaceKey.app into ./build using only the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FaceKey.app"
MODEL_CACHE="build/ArcFace.mlmodelc"

echo "==> Compiling Swift sources"
swift build -c release

echo "==> Compiling the face model (cached after the first run)"
if [[ ! -d "$MODEL_CACHE" || "Resources/ArcFace.mlpackage/Data/com.apple.CoreML/model.mlmodel" -nt "$MODEL_CACHE" ]]; then
    swift Scripts/compile-model.swift Resources/ArcFace.mlpackage "$MODEL_CACHE"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FaceKey "$APP/Contents/MacOS/FaceKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R "$MODEL_CACHE" "$APP/Contents/Resources/ArcFace.mlmodelc"
cp LICENSE-Glance.txt "$APP/Contents/Resources/LICENSE-Glance.txt"
cp Resources/unlockanimation.mp4 Resources/unsuccessfulunlockanimation.mp4 Resources/unlockstatic.png "$APP/Contents/Resources/"

# If a code-signing certificate named "FaceKey Local Signing" exists in the login keychain, sign with it:
# the app then keeps the same identity across rebuilds, so Camera, Accessibility and keychain access survive.
# Create one yourself in Keychain Access: Certificate Assistant > Create a Certificate, name it exactly
# "FaceKey Local Signing", Identity Type "Self-Signed Root", Certificate Type "Code Signing".
IDENTITY="FaceKey Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "==> Signing with \"$IDENTITY\""
    codesign --force --sign "$IDENTITY" --identifier local.facekey "$APP"
else
    echo "==> Signing (ad-hoc)"
    # Ad-hoc signing has no identity behind it, so macOS ties the Camera and Accessibility grants to this
    # exact build. After every rebuild those permissions must be granted again.
    codesign --force --sign - --identifier local.facekey "$APP"
fi

echo "Built $APP"
