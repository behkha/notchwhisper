#!/bin/bash
# Build NotchWhisper as a macOS .app (universal-capable) via SwiftPM + manual packaging.
set -euo pipefail

APP="NotchWhisper"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP_BUNDLE="$BUILD/$APP.app"
BIN="$APP_BUNDLE/Contents/MacOS/$APP"
RES="$APP_BUNDLE/Contents/Resources"
FRI="$APP_BUNDLE/Contents/Frameworks"
MIN_MACOS="14.0"

echo "==> Resolving dependencies (WhisperKit)"
pushd "$ROOT" >/dev/null
swift package resolve 2>&1 | tail -5

# Universal (Intel x86_64 + Apple Silicon arm64) build when UNIVERSAL=1.
# A single Apple Silicon runner can cross-compile x86_64, so this produces one
# app that runs on both architectures — no need for two separate downloads.
UNIVERSAL="${UNIVERSAL:-0}"
ARCH_FLAGS=""
if [ "$UNIVERSAL" = "1" ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
  echo "==> Building universal (arm64 + x86_64) release executable"
else
  echo "==> Building release executable (host architecture)"
fi
swift build -c release $ARCH_FLAGS 2>&1 | tail -40
BIN_SRC="$(swift build -c release $ARCH_FLAGS --show-bin-path | tr -d '[:space:]')"
popd >/dev/null

if [ ! -x "$BIN_SRC/$APP" ]; then
  echo "!! Could not find built executable at $BIN_SRC/$APP"
  exit 1
fi

echo "==> Assembling .app"
rm -rf "$APP_BUNDLE"
mkdir -p "$FRI" "$RES" "$APP_BUNDLE/Contents/MacOS"

cp "$BIN_SRC/$APP" "$BIN"

# When building universal, confirm the binary actually contains both slices.
if [ "$UNIVERSAL" = "1" ]; then
  echo "==> Verifying universal binary"
  lipo -info "$BIN" 2>/dev/null || true
fi

# App icon (regenerate with: swift scripts/make_icon.swift && iconutil -c icns /tmp/AppIcon.iconset -o build/AppIcon.icns)
if [ -f "$BUILD/AppIcon.icns" ]; then
  cp "$BUILD/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Bundle any dylibs SwiftPM emitted alongside the executable.
find "$BIN_SRC" -maxdepth 1 -name "*.dylib" -exec cp {} "$FRI/" \; || true
if [ -n "$(ls -A "$FRI" 2>/dev/null)" ]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>NotchWhisper</string>
  <key>CFBundleIdentifier</key><string>com.behkha.notchwhisper</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>NotchWhisper uses your microphone to transcribe your voice locally, on-device.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>NotchWhisper needs Input Monitoring to listen for the hold-to-talk hotkey while you use other apps.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>NotchWhisper needs Accessibility access to type your transcript into the focused text field.</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Background agent: no Dock icon. Lives in the menu bar + notch; the
       main window is opened explicitly from the menu bar item. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cat > "$BUILD/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT

echo "==> Code-signing"
# Sign with a stable self-signed identity ("NotchWhisper Dev") so TCC grants
# (Accessibility, Input Monitoring, Microphone) survive rebuilds. Ad-hoc "-"
# mints a new CDHash every build, which silently orphans those permissions.
SIGN_ID="${NOTCHWHISPER_IDENTITY:-NotchWhisper Dev}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo "!! Signing identity '$SIGN_ID' not found — run ./setup_signing_identity.sh first"
  echo "   Falling back to ad-hoc signing (TCC permissions will reset on next build)."
  SIGN_ID="-"
fi
codesign --force --deep --sign "$SIGN_ID" \
  --entitlements "$BUILD/entitlements.plist" \
  "$APP_BUNDLE" 2>&1 | tail -5 || true

xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "✓ built $APP_BUNDLE"
