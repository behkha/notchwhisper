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

echo "==> Vendoring llama.cpp (Qwen3-ASR backend)"
"$ROOT/scripts/fetch_llama.sh"

echo "==> Resolving dependencies (WhisperKit)"
pushd "$ROOT" >/dev/null
swift package resolve 2>&1 | tail -5

# Architecture selection.
#   ARCH=arm64      -> Apple Silicon only
#   ARCH=x86_64     -> Intel only
#   ARCH=universal  -> both slices in one binary (or set UNIVERSAL=1)
#   (unset)         -> host architecture (fast local dev)
#
# Important: we deliberately do NOT pass `--arch arm64 --arch x86_64` together
# to a single `swift build`. SwiftPM throws "duplicate key found:
# ID(moduleName: "ArgmaxCLI", packageIdentity: whisperkit)" for packages that
# ship an executable target (WhisperKit's CLI) when both slices are requested
# at once. For `universal` we therefore build each slice separately and merge
# them with `lipo -create`, which yields a genuine universal binary.
UNIVERSAL="${UNIVERSAL:-0}"
ARCH="${ARCH:-}"
ARCH_FLAGS=""
DO_UNIVERSAL=0
VERIFY=0
if [ "$ARCH" = "universal" ] || [ "$UNIVERSAL" = "1" ]; then
  DO_UNIVERSAL=1
  VERIFY=1
  echo "==> Building universal (arm64 + x86_64) release executable"
elif [ "$ARCH" = "arm64" ]; then
  ARCH_FLAGS="--arch arm64"
  VERIFY=1
  echo "==> Building arm64 (Apple Silicon) release executable"
elif [ "$ARCH" = "x86_64" ]; then
  ARCH_FLAGS="--arch x86_64"
  VERIFY=1
  echo "==> Building x86_64 (Intel) release executable"
else
  echo "==> Building release executable (host architecture)"
fi

if [ "$DO_UNIVERSAL" = "1" ]; then
  TMP="$(mktemp -d)"
  # arm64 slice
  swift build -c release --arch arm64 2>&1 | tail -40
  SRC_ARM="$(swift build -c release --arch arm64 --show-bin-path | tr -d '[:space:]')"
  mkdir -p "$TMP/arm64" && cp -R "$SRC_ARM/." "$TMP/arm64/"
  # x86_64 slice
  swift build -c release --arch x86_64 2>&1 | tail -40
  SRC_X86="$(swift build -c release --arch x86_64 --show-bin-path | tr -d '[:space:]')"
  mkdir -p "$TMP/x86_64" && cp -R "$SRC_X86/." "$TMP/x86_64/"
  # Merge the main executable (fall back to whichever slice exists).
  if [ -e "$TMP/arm64/$APP" ] && [ -e "$TMP/x86_64/$APP" ]; then
    lipo -create -output "$TMP/$APP" "$TMP/arm64/$APP" "$TMP/x86_64/$APP"
  elif [ -e "$TMP/arm64/$APP" ]; then
    cp "$TMP/arm64/$APP" "$TMP/$APP"
  else
    cp "$TMP/x86_64/$APP" "$TMP/$APP"
  fi
  # Merge any dylibs SwiftPM emitted so the Frameworks dir is universal too.
  for dylib in "$TMP"/arm64/*.dylib; do
    [ -e "$dylib" ] || continue
    name="$(basename "$dylib")"
    if [ -e "$TMP/x86_64/$name" ]; then
      lipo -create -output "$TMP/$name" "$TMP/arm64/$name" "$TMP/x86_64/$name"
    else
      cp "$TMP/arm64/$name" "$TMP/$name"
    fi
  done
  BIN_SRC="$TMP"
else
  swift build -c release $ARCH_FLAGS 2>&1 | tail -40
  BIN_SRC="$(swift build -c release $ARCH_FLAGS --show-bin-path | tr -d '[:space:]')"
fi
popd >/dev/null

if [ ! -x "$BIN_SRC/$APP" ]; then
  echo "!! Could not find built executable at $BIN_SRC/$APP"
  exit 1
fi

echo "==> Assembling .app"
rm -rf "$APP_BUNDLE"
mkdir -p "$FRI" "$RES" "$APP_BUNDLE/Contents/MacOS"

cp "$BIN_SRC/$APP" "$BIN"

# When building for a specific architecture (or universal), confirm the binary
# contains the expected slice(s).
if [ "$VERIFY" = "1" ]; then
  echo "==> Verifying binary architectures"
  lipo -info "$BIN" 2>/dev/null || true
fi

# App icon (regenerate with: swift scripts/make_icon.swift && iconutil -c icns /tmp/AppIcon.iconset -o build/AppIcon.icns)
if [ -f "$BUILD/AppIcon.icns" ]; then
  cp "$BUILD/AppIcon.icns" "$RES/AppIcon.icns"
fi

# Bundle any dylibs SwiftPM emitted alongside the executable.
find "$BIN_SRC" -maxdepth 1 -name "*.dylib" -exec cp {} "$FRI/" \; || true

# Bundle the vendored llama.cpp / mtmd libraries (the Qwen3-ASR backend). These
# aren't emitted by SwiftPM — they live in vendor/llama/lib — so copy the real
# (unversioned-major) dylibs explicitly. Their install names are @rpath/… so the
# Frameworks rpath below resolves them.
if [ -d "$ROOT/vendor/llama/lib" ]; then
  find "$ROOT/vendor/llama/lib" -maxdepth 1 -name "*.0.dylib" -exec cp {} "$FRI/" \; || true
fi

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
