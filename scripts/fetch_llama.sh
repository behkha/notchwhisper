#!/bin/bash
# Vendor the prebuilt llama.cpp libraries + headers used by the Qwen3-ASR
# (llama.cpp / mtmd) transcription backend.
#
# Downloads the pinned llama.cpp release for both macOS architectures, merges
# each needed dylib into a universal (arm64 + x86_64) binary under
# vendor/llama/lib/, and fetches the matching public headers into
# vendor/llama/include/.
#
# Idempotent: does nothing when vendor/llama/lib/libmtmd.0.dylib already exists.
# To move to a newer llama.cpp: bump LLAMA_CPP_BUILD and delete vendor/llama/lib.
set -euo pipefail

LLAMA_CPP_BUILD="b10712"
REPO="ggml-org/llama.cpp"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/llama"
LIB="$VENDOR/lib"
INC="$VENDOR/include"

# The libraries the app links + loads. libmtmd pulls in the rest.
LIBS=(mtmd llama ggml ggml-base ggml-cpu ggml-blas ggml-metal ggml-rpc)

if [ -f "$LIB/libmtmd.0.dylib" ]; then
  echo "==> vendor/llama already populated (build $LLAMA_CPP_BUILD) — nothing to do"
  echo "    (delete $LIB to re-fetch / change LLAMA_CPP_BUILD)"
  exit 0
fi

echo "==> Vendoring llama.cpp $LLAMA_CPP_BUILD"
mkdir -p "$LIB" "$INC"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_slice() {
  local arch="$1" tarball url
  tarball="llama-$LLAMA_CPP_BUILD-bin-macos-$arch.tar.gz"
  url="https://github.com/$REPO/releases/download/$LLAMA_CPP_BUILD/$tarball"
  echo "  · downloading $tarball"
  curl -fsSL "$url" -o "$TMP/$arch.tar.gz"
  mkdir -p "$TMP/$arch"
  tar xzf "$TMP/$arch.tar.gz" -C "$TMP/$arch" --strip-components=1
}

fetch_slice arm64
fetch_slice x64

# Resolve a possibly-symlinked dylib to its real Mach-O file. The real file in
# each slice is the fully-versioned name (libX.<maj>.<min>.<patch>.dylib);
# libX.0.dylib and libX.dylib are symlinks to it.
resolve_real() {
  local p="$1"
  if command -v greadlink >/dev/null 2>&1; then greadlink -f "$p" 2>/dev/null && return; fi
  if readlink -f "$p" >/dev/null 2>&1; then readlink -f "$p"; return; fi
  # Fallback: glob the versioned sibling in the same dir.
  local dir base; dir="$(dirname "$p")"; base="$(basename "$p" .0.dylib)"
  ls "$dir/$base".*.*.*.dylib 2>/dev/null | head -1
}

echo "==> Merging universal dylibs"
for name in "${LIBS[@]}"; do
  arm_real="$(resolve_real "$TMP/arm64/lib$name.0.dylib")"
  x64_real="$(resolve_real "$TMP/x64/lib$name.0.dylib")"
  [ -f "$arm_real" ] || arm_real="$TMP/arm64/lib$name.0.dylib"
  [ -f "$x64_real" ] || x64_real="$TMP/x64/lib$name.0.dylib"
  if [ ! -f "$arm_real" ]; then echo "!! missing lib$name in arm64 slice"; exit 1; fi
  if [ -f "$x64_real" ]; then
    lipo -create -output "$LIB/lib$name.0.dylib" "$arm_real" "$x64_real"
  else
    echo "  · lib$name: arm64 only"
    cp "$arm_real" "$LIB/lib$name.0.dylib"
  fi
  # Install name is @rpath/libX.0.dylib — keep it. Add the unversioned symlink
  # the linker needs for -lX at build time.
  install_name_tool -id "@rpath/lib$name.0.dylib" "$LIB/lib$name.0.dylib" 2>/dev/null || true
  ln -sf "lib$name.0.dylib" "$LIB/lib$name.dylib"
done
chmod 0644 "$LIB"/*.0.dylib

echo "==> Fetching headers"
raw="https://raw.githubusercontent.com/$REPO/$LLAMA_CPP_BUILD"
get_header() { curl -fsSL "$raw/$1" -o "$INC/$(basename "$1")"; }
get_header "include/llama.h"
get_header "ggml/include/ggml.h"
get_header "ggml/include/ggml-cpu.h"
get_header "ggml/include/ggml-backend.h"
get_header "ggml/include/ggml-alloc.h"
get_header "ggml/include/ggml-opt.h"
get_header "ggml/include/gguf.h"
get_header "tools/mtmd/mtmd.h"
get_header "tools/mtmd/mtmd-helper.h"

# LICENSE (llama.cpp is MIT).
curl -fsSL "$raw/LICENSE" -o "$VENDOR/LICENSE-llama.cpp"

cat > "$VENDOR/BUILD.txt" <<EOF
llama.cpp vendored libraries + headers
build: $LLAMA_CPP_BUILD
source: https://github.com/$REPO/releases/tag/$LLAMA_CPP_BUILD
regenerate: scripts/fetch_llama.sh (bump LLAMA_CPP_BUILD, delete vendor/llama/lib)
EOF

echo "✓ vendored llama.cpp $LLAMA_CPP_BUILD into vendor/llama"
ls -la "$LIB"
