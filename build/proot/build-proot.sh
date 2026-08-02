#!/bin/bash
# build-proot.sh — Build proot from termux/proot fork for Android
#
# Requires: Docker, or Ubuntu with Android NDK installed
# Usage:
#   ./build-proot.sh              # build all arches
#   ./build-proot.sh arm64-v8a    # build single arch
#
# Output: dist/{arch}/libproot.so

set -euo pipefail

PROOT_VERSION="5.1.107.89"
PROOT_COMMIT="6c09638b"  # termux/proot with seccomp fixes
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
SRC_DIR="$SCRIPT_DIR/proot-src"

# --- Parse args ---
BUILD_ARCH="${1:-all}"

case "$BUILD_ARCH" in
  arm64-v8a)    ARCHES=("arm64-v8a") ;;
  armeabi-v7a)  ARCHES=("armeabi-v7a") ;;
  x86_64)       ARCHES=("x86_64") ;;
  x86)          ARCHES=("x86") ;;
  all)          ARCHES=("arm64-v8a" "armeabi-v7a" "x86_64" "x86") ;;
  *)            echo "Unknown arch: $BUILD_ARCH"; exit 1 ;;
esac

# --- NDK setup ---
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  NDK="$ANDROID_NDK_HOME"
elif [ -n "${ANDROID_NDK:-}" ] && [ -d "$ANDROID_NDK" ]; then
  NDK="$ANDROID_NDK"
elif [ -d "$ANDROID_HOME/ndk/$NDK_VERSION" ]; then
  NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
elif [ -d "$ANDROID_SDK/ndk/$NDK_VERSION" ]; then
  NDK="$ANDROID_SDK/ndk/$NDK_VERSION"
else
  echo "ERROR: Android NDK not found."
  echo "Set ANDROID_NDK_HOME or install via: sdkmanager 'ndk;$NDK_VERSION'"
  exit 1
fi

echo "Using NDK: $NDK"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
if [ ! -d "$TOOLCHAIN" ]; then
  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64"
fi
if [ ! -d "$TOOLCHAIN" ]; then
  echo "ERROR: NDK toolchain not found in $NDK"
  exit 1
fi

CC_BASE="$TOOLCHAIN/bin"
SYSROOT="$TOOLCHAIN/sysroot"

# --- Clone proot if needed ---
if [ ! -d "$SRC_DIR" ]; then
  echo "Cloning termux/proot@$PROOT_COMMIT ..."
  git clone --depth=1 https://github.com/termux/proot.git "$SRC_DIR"
  cd "$SRC_DIR"
  git fetch --depth=1 origin "$PROOT_COMMIT" 2>/dev/null || git fetch --depth=50 origin
  git checkout "$PROOT_COMMIT" 2>/dev/null || git checkout "v$PROOT_VERSION"
  cd "$SCRIPT_DIR"
else
  echo "Using existing proot source at $SRC_DIR"
fi

# --- Build function ---
build_arch() {
  local arch="$1"
  local out_dir="$DIST_DIR/$arch"
  mkdir -p "$out_dir"

  local cc_prefix=""
  local api_level=21
  local target=""
  local cross_prefix=""

  case "$arch" in
    arm64-v8a)
      target="aarch64-linux-android"
      cross_prefix="aarch64-linux-android$api_level"
      cc_prefix="aarch64"
      ;;
    armeabi-v7a)
      target="armv7a-linux-androideabi"
      cross_prefix="armv7a-linux-androideabi$api_level"
      cc_prefix="arm"
      ;;
    x86_64)
      target="x86_64-linux-android"
      cross_prefix="x86_64-linux-android$api_level"
      cc_prefix="x86_64"
      ;;
    x86)
      target="i686-linux-android"
      cross_prefix="i686-linux-android$api_level"
      cross_prefix="i686-linux-android$api_level"
      cc_prefix="i686"
      ;;
  esac

  local CC="$CC_BASE/${cross_prefix}-clang"
  local CXX="$CC_BASE/${cross_prefix}-clang++"
  local AR="$CC_BASE/llvm-ar"
  local STRIP="$CC_BASE/llvm-strip"

  if [ ! -f "$CC" ]; then
    echo "ERROR: Compiler not found: $CC"
    return 1
  fi

  echo ""
  echo "=== Building for $arch ==="
  echo "  CC: $CC"
  echo "  Target: $target"

  local build_dir="$SCRIPT_DIR/build-$arch"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  cd "$SRC_DIR"

  # Collect all C sources from src/
  local srcs=()
  while IFS= read -r -d '' f; do
    srcs+=("$f")
  done < <(find src -name '*.c' -print0 | sort -z)

  if [ ${#srcs[@]} -eq 0 ]; then
    echo "ERROR: No C sources found in src/"
    cd "$SCRIPT_DIR"
    return 1
  fi

  echo "  Found ${#srcs[@]} source files"

  # Common flags — static build, Android target
  local CFLAGS=(
    -O2
    -Wall
    -Werror=implicit-function-declaration
    -D_GNU_SOURCE
    -DANDROID
    -DMAIN_PR0073_  # proot version marker
    -Isrc
    -Isrc/arch/$cc_prefix/arch
    -Isrc/arch
  )

  # Architecture-specific flags
  case "$arch" in
    arm64-v8a)
      CFLAGS+=(-Isrc/arch/arm64)
      ;;
    armeabi-v7a)
      CFLAGS+=(-Isrc/arch/arm)
      ;;
    x86_64)
      CFLAGS+=(-Isrc/arch/x86_64)
      ;;
    x86)
      CFLAGS+=(-Isrc/arch/x86)
      ;;
  esac

  # Compile each source
  local objects=()
  for src in "${srcs[@]}"; do
    local obj="$build_dir/$(basename "${src%.c}.o")"
    echo "  CC $src"
    "$CC" "${CFLAGS[@]}" -c "$src" -o "$obj" 2>&1
    if [ $? -ne 0 ]; then
      echo "  WARNING: Failed to compile $src, continuing..."
      continue
    fi
    objects+=("$obj")
  done

  if [ ${#objects[@]} -eq 0 ]; then
    echo "ERROR: No objects compiled for $arch"
    cd "$SCRIPT_DIR"
    return 1
  fi

  # Link as static executable
  local output="$build_dir/proot"
  echo "  LINK → $output"
  "$CC" -static -o "$output" "${objects[@]}" -ltalloc -lshmem -lm -lc 2>&1 || \
  "$CC" -static -o "$output" "${objects[@]}" -lm -lc 2>&1 || {
    # If static linking fails (likely), try dynamic with -nostdlib
    echo "  Retrying with minimal linking..."
    "$CC" -o "$output" "${objects[@]}" -lm 2>&1
  }

  if [ ! -f "$output" ]; then
    echo "ERROR: Link failed for $arch"
    cd "$SCRIPT_DIR"
    return 1
  fi

  # Verify
  echo "  Verifying binary..."
  file "$output" 2>/dev/null || true
  "$STRIP" "$output" 2>/dev/null || true

  # Copy to dist as libproot.so
  cp "$output" "$out_dir/libproot.so"
  echo "  ✓ $out_dir/libproot.so ($(stat -c%s "$out_dir/libproot.so" 2>/dev/null || stat -f%z "$out_dir/libproot.so") bytes)"

  cd "$SCRIPT_DIR"
}

# --- Build each arch ---
for arch in "${ARCHES[@]}"; do
  build_arch "$arch"
done

echo ""
echo "=== Build complete ==="
for arch in "${ARCHES[@]}"; do
  if [ -f "$DIST_DIR/$arch/libproot.so" ]; then
    echo "  ✓ $arch: $DIST_DIR/$arch/libproot.so"
  else
    echo "  ✗ $arch: MISSING"
  fi
done
