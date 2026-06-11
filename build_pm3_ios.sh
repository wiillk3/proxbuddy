#!/bin/bash
# build_pm3_ios.sh
# Cross-compiles the Iceman/RRG pm3 client for arm64-apple-ios26.
# Output: ProxBuddy/Resources/pm3client
#
# Usage:
#   ./build_pm3_ios.sh [path/to/proxmark3]
#
# Re-runnable: pulls latest source, rebuilds, replaces binary.
# Pass --clean to wipe the build cache first.
#
# Design notes:
#   - We do NOT use a CMake toolchain file. The pm3 CMakeLists.txt has an
#     `if(CMAKE_TOOLCHAIN_FILE)` block that auto-enables EMBED_READLINE,
#     EMBED_BZIP2, EMBED_LZ4, EMBED_GD and only sets CFLAGS_EXTERNAL_LIB for
#     Android. Omitting the toolchain file skips this block entirely.
#   - Instead we pass -DCMAKE_SYSTEM_NAME=iOS plus all compiler/sysroot vars
#     directly. CMake 3.14+ has native iOS cross-compilation support.
#   - bzip2 and lz4 are pre-built for iOS before cmake runs so cmake's
#     find_package/find_library picks up the iOS statics.
#   - readline/ncurses are replaced by linenoise (SKIPREADLINE=1).
#   - GD (image lib) is skipped (SKIPGD=1) — not needed for BLE-only client.
#   - stdlib.h marks POSIX functions __IOS_PROHIBITED. Defining
#     -D__IOS_PROHIBITED= at compile time suppresses all of them, mirroring
#     the manual SDK patch in doc/md/Installation_Instructions/iOS-*.md.
set -euo pipefail

# Ensure we always restore the user's CMakeLists.txt even if the script fails midway
cleanup() {
    if [ -d "$PM3_SRC/.git" ]; then
        git -C "$PM3_SRC" restore client/CMakeLists.txt 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Args ──────────────────────────────────────────────────────────────────────

CLEAN=0
PM3_SRC_ARG=""
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *)  PM3_SRC_ARG="$arg" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PM3_SRC="${PM3_SRC_ARG:-/Users/williamkellner/d3v/proxmark/proxmark3}"
OUTPUT="$SCRIPT_DIR/ProxBuddy/Resources/libpm3client.dylib"
BUILD_DIR="/tmp/pm3-ios-build"

if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning $BUILD_DIR..."
    rm -rf "$BUILD_DIR"
fi

IOS_TARGET="26.0"
ARCH="arm64"
TRIPLE="${ARCH}-apple-ios${IOS_TARGET}"

# ── Toolchain ─────────────────────────────────────────────────────────────────

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_CC="$(xcrun --sdk iphoneos -f clang)"
IOS_CXX="$(xcrun --sdk iphoneos -f clang++)"
IOS_AR="$(xcrun --sdk iphoneos -f ar)"
IOS_RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
IOS_STRIP="$(xcrun --sdk iphoneos -f strip)"

echo "==> iOS SDK : $IOS_SDK"
echo "==> Clang   : $IOS_CC"
echo "==> PM3 src : $PM3_SRC"

CFLAGS="-target ${TRIPLE} -isysroot ${IOS_SDK} -Os -D__IOS_PROHIBITED= -DLIBPM3 -Wno-error=unused-but-set-variable"
CXXFLAGS="$CFLAGS -std=c++11"
LDFLAGS="-target ${TRIPLE} -isysroot ${IOS_SDK}"

# ── Refresh source ────────────────────────────────────────────────────────────

if [ -d "$PM3_SRC/.git" ]; then
    echo "==> Updating Iceman source..."
    git -C "$PM3_SRC" pull --ff-only \
        || echo "warning: git pull failed, continuing with current source"
fi

# ── linenoise setup (required for SKIPREADLINE=1) ─────────────────────────────

LINENOISE_DIR="$PM3_SRC/client/deps/linenoise"
if [ ! -d "$LINENOISE_DIR" ]; then
    echo "==> Setting up linenoise..."
    (cd "$PM3_SRC/client/deps" && bash get_linenoise.sh)
fi

# ── Pre-build bzip2 for iOS ───────────────────────────────────────────────────
# pm3 uses android external bzip2; we build it for iOS ahead of cmake so
# find_package(BZip2) picks up our iOS static lib instead of the macOS one.

BZIP2_SRC="$BUILD_DIR/bzip2-src"
BZIP2_LIB="$BUILD_DIR/bzip2-src/libbz2.a"

if [ ! -f "$BZIP2_LIB" ]; then
    echo "==> Cloning bzip2..."
    rm -rf "$BZIP2_SRC"
    git clone --depth 1 -b platform-tools-30.0.2 \
        https://android.googlesource.com/platform/external/bzip2 "$BZIP2_SRC"

    echo "==> Building bzip2 for iOS..."
    make -C "$BZIP2_SRC" -j"$(sysctl -n hw.ncpu)" \
        CC="$IOS_CC" \
        CFLAGS="$CFLAGS" \
        AR="$IOS_AR" \
        RANLIB="$IOS_RANLIB" \
        libbz2.a
fi

# ── Pre-build lz4 for iOS ─────────────────────────────────────────────────────

LZ4_SRC="$BUILD_DIR/lz4-src"
LZ4_LIB="$BUILD_DIR/lz4-src/lib/liblz4.a"

if [ ! -f "$LZ4_LIB" ]; then
    echo "==> Cloning lz4..."
    rm -rf "$LZ4_SRC"
    git clone --depth 1 -b platform-tools-30.0.2 \
        https://android.googlesource.com/platform/external/lz4 "$LZ4_SRC"

    echo "==> Building lz4 for iOS..."
    make -C "$LZ4_SRC/lib" -j"$(sysctl -n hw.ncpu)" \
        CC="$IOS_CC" \
        CFLAGS="$CFLAGS" \
        AR="$IOS_AR" \
        RANLIB="$IOS_RANLIB" \
        liblz4.a
fi

PYTHON_VER="3.11-b8"
PYTHON_URL="https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_VER}/Python-3.11-iOS-support.b8.tar.gz"
PYTHON_DIR="$BUILD_DIR/python-ios"
PYTHON_XCFRAMEWORK="$SCRIPT_DIR/ProxBuddy/Python.xcframework"
PYTHON_STDLIB_ZIP="$SCRIPT_DIR/ProxBuddy/Resources/python311.zip"
PYTHON_INC_DIR="$PYTHON_XCFRAMEWORK/ios-arm64/Python.framework/Headers"
PYTHON_LIB="$PYTHON_XCFRAMEWORK/ios-arm64/Python.framework/Python"

# ── Patch CMakeLists.txt for dylib and Python ────────────────────────────────
echo "==> Patching CMakeLists.txt to build SHARED library..."
sed -i '' 's/add_executable(proxmark3/add_library(proxmark3 SHARED/g' "$PM3_SRC/client/CMakeLists.txt"
echo "==> Patching CMakeLists.txt to force Python for iOS..."
sed -i '' 's|pkg_search_module(PYTHON3EMBED QUIET ${PYTHON3_PKGCONFIG}-embed)|set(PYTHON3EMBED_FOUND TRUE)\n    set(PYTHON3EMBED_INCLUDE_DIRS "'"${PYTHON_INC_DIR}"'")\n    set(PYTHON3EMBED_LIBRARIES "'"${PYTHON_LIB}"'")\n    set(PYTHON3EMBED_LIBRARY_DIRS "")|g' "$PM3_SRC/client/CMakeLists.txt"

# ── Pre-build Python for iOS ──────────────────────────────────────────────────
# Download BeeWare Python-Apple-support framework

if [ ! -d "$PYTHON_XCFRAMEWORK" ]; then
    echo "==> Downloading BeeWare Python $PYTHON_VER..."
    mkdir -p "$PYTHON_DIR"
    curl -sL "$PYTHON_URL" -o "$PYTHON_DIR/python.tar.gz"
    tar -xzf "$PYTHON_DIR/python.tar.gz" -C "$PYTHON_DIR"
    
    echo "==> Installing Python.xcframework..."
    cp -R "$PYTHON_DIR/Python.xcframework" "$PYTHON_XCFRAMEWORK"
    
    echo "==> Zipping Python standard library..."
    # Python can import standard library modules directly from a zip!
    mkdir -p "$SCRIPT_DIR/ProxBuddy/Resources"
    rm -f "$PYTHON_STDLIB_ZIP"
    (cd "$PYTHON_DIR/Python.xcframework/lib/python3.11" && zip -r -q "$PYTHON_STDLIB_ZIP" .)
fi


# ── CMake configure ───────────────────────────────────────────────────────────
# No -DCMAKE_TOOLCHAIN_FILE — that's intentional. See header comment.

mkdir -p "$BUILD_DIR/cmake"
cd "$BUILD_DIR/cmake"

cmake "$PM3_SRC/client" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_TARGET}" \
    -DCMAKE_OSX_SYSROOT="${IOS_SDK}" \
    -DCMAKE_C_COMPILER="${IOS_CC}" \
    -DCMAKE_CXX_COMPILER="${IOS_CXX}" \
    -DCMAKE_AR="${IOS_AR}" \
    -DCMAKE_RANLIB="${IOS_RANLIB}" \
    -DCMAKE_BUILD_TYPE=Release \
    \
    -DSKIPREADLINE=1  \
    -DSKIPGD=1        \
    -DSKIPQT=1        \
    -DSKIPBT=1        \
    -DSKIPPYTHON=0    \
    \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
    \
    -DPython3_INCLUDE_DIR="${PYTHON_INC_DIR}" \
    -DPython3_LIBRARY="${PYTHON_LIB}" \
    -DPYTHON_INCLUDE_DIR="${PYTHON_INC_DIR}" \
    -DPYTHON_LIBRARY="${PYTHON_LIB}" \
    \
    -DBZIP2_INCLUDE_DIR="${BZIP2_SRC}" \
    -DBZIP2_LIBRARY="${BZIP2_LIB}" \
    -DLZ4_INCLUDE_DIRS="${LZ4_SRC}/lib" \
    -DLZ4_LIBRARIES="${LZ4_LIB}" \
    2>&1 | tee cmake-configure.log

# ── Build ─────────────────────────────────────────────────────────────────────

echo "==> Building pm3 client ($(sysctl -n hw.ncpu) jobs)..."
make -j"$(sysctl -n hw.ncpu)" 2>&1 | tee build.log

# ── Locate binary ─────────────────────────────────────────────────────────────

PM3_BIN="$(find "$BUILD_DIR/cmake" -name "libproxmark3.dylib" -type f | head -1)"
if [ -z "$PM3_BIN" ]; then
    echo "ERROR: libproxmark3.dylib binary not found"
    echo "Check $BUILD_DIR/cmake/build.log"
    exit 1
fi

echo "==> Binary  : $PM3_BIN"
file "$PM3_BIN"

# ── Strip and copy ────────────────────────────────────────────────────────────

"$IOS_STRIP" "$PM3_BIN" 2>/dev/null || true

mkdir -p "$(dirname "$OUTPUT")"
cp "$PM3_BIN" "$OUTPUT"
chmod +x "$OUTPUT"

# ── Copy pm3 resources ────────────────────────────────────────────────────────
# The client locates luascripts, dictionaries etc. relative to itself via
# whereami(). Bundle them so pm3 finds them at runtime.

PM3_RES_SRC="$PM3_SRC/client"
PM3_RES_DEST="$SCRIPT_DIR/ProxBuddy/Resources"

for dir in luascripts lualibs dictionaries pyscripts cmdscripts; do
    if [ -d "$PM3_RES_SRC/$dir" ]; then
        echo "==> Copying $dir..."
        rm -rf "$PM3_RES_DEST/$dir"
        cp -R "$PM3_RES_SRC/$dir" "$PM3_RES_DEST/$dir"
    fi
done

echo ""
echo "==> Done. Binary: $OUTPUT"
echo "==> Build log:    $BUILD_DIR/cmake/build.log"

# ── Cleanup ───────────────────────────────────────────────────────────────────
echo "==> All done!"
