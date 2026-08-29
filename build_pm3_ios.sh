#!/bin/bash
# build_pm3_ios.sh
# Cross-compiles the Iceman/RRG pm3 client for arm64-apple-ios.
# Output: ProxBuddy/Resources/libpm3client.dylib
#
# Usage:
#   ./build_pm3_ios.sh [path/to/proxmark3] [--clean] [--update-pm3-git]
#
# Re-runnable: rebuilds and replaces binary.
# Pass --clean to wipe the build cache first.
# Pass --update-pm3-git to pull latest Iceman source before building.
#
# Design notes:
#   - We do NOT use a CMake toolchain file. The pm3 CMakeLists.txt has an
#     `if(CMAKE_TOOLCHAIN_FILE)` block that auto-enables EMBED_READLINE,
#     EMBED_BZIP2, EMBED_LZ4, EMBED_GD and only sets CFLAGS_EXTERNAL_LIB for
#     Android. Omitting the toolchain file skips this block entirely.
#   - Instead we pass -DCMAKE_SYSTEM_NAME=iOS plus all compiler/sysroot vars
#     directly. CMake 3.14+ has native iOS cross-compilation support.
#   - A git-format patch (patches/ios-shared-lib.patch) converts
#     add_executable → add_library(SHARED) and injects iOS Python paths.
#   - bzip2 and lz4 are pre-built for iOS before cmake runs so cmake's
#     find_package/find_library picks up the iOS statics.
#   - readline/ncurses are replaced by linenoise (SKIPREADLINE=1).
#   - GD (image lib) is skipped (SKIPGD=1) — not needed for BLE-only client.
#   - stdlib.h marks POSIX functions __IOS_PROHIBITED. Defining
#     -D__IOS_PROHIBITED= at compile time suppresses all of them, mirroring
#     the manual SDK patch in doc/md/Installation_Instructions/iOS-*.md.
set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────

CLEAN=0
UPDATE_GIT=0
PM3_SRC_ARG=""
for arg in "$@"; do
    case "$arg" in
        --clean)          CLEAN=1 ;;
        --update-pm3-git) UPDATE_GIT=1 ;;
        -*)               echo "Unknown flag: $arg"; exit 1 ;;
        *)                PM3_SRC_ARG="$arg" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PM3_SRC_ENV="${PM3_SRC:-}"
OUTPUT="$SCRIPT_DIR/ProxBuddy/Resources/libpm3client.dylib"
BUILD_DIR="/tmp/pm3-ios-build"

if [ -n "$PM3_SRC_ARG" ]; then
    PM3_SRC="$PM3_SRC_ARG"
elif [ -n "$PM3_SRC_ENV" ]; then
    PM3_SRC="$PM3_SRC_ENV"
else
    PM3_SRC=""
    for candidate in "$SCRIPT_DIR/../proxmark3" "$HOME/proxmark3"; do
        if [ -d "$candidate/client" ]; then
            PM3_SRC="$candidate"
            break
        fi
    done
fi

if [ -z "$PM3_SRC" ] || [ ! -d "$PM3_SRC/client" ]; then
    echo "Usage: $0 [path/to/proxmark3] [--clean] [--update-pm3-git]"
    echo "Pass the Iceman clone path, or set PM3_SRC."
    echo "Looked in: ../proxmark3 and \$HOME/proxmark3"
    exit 1
fi
PM3_SRC="$(cd "$PM3_SRC" && pwd)"

# Ensure we always restore the upstream CMakeLists.txt even if the script fails
cleanup() {
    if [ -d "$PM3_SRC/.git" ]; then
        git -C "$PM3_SRC" checkout -- client/CMakeLists.txt client/src/pm3.c 2>/dev/null || true
    fi
}
trap cleanup EXIT

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
echo "==> ar      : $IOS_AR"
echo "==> PM3 src : $PM3_SRC"

# Homebrew binutils/llvm put a GNU `ar` on PATH. GNU archives contain a `//`
# symbol-index member that Apple ld rejects:
#   ld: archive member '//' not a mach-o file in '.../libcrypto.a'
export PATH="/usr/bin:$(dirname "$IOS_AR"):$PATH"
export AR="$IOS_AR"
export RANLIB="$IOS_RANLIB"
export CC="$IOS_CC"
export CXX="$IOS_CXX"

is_apple_archive() {
    local lib="$1"
    [ -f "$lib" ] || return 1
    file "$lib" | grep -q "ar archive" || return 1
    local members
    members="$("$IOS_AR" -t "$lib" 2>/dev/null || true)"
    [ -n "$members" ] || return 1
    # GNU ar's SysV index / long-name table: Apple ld rejects these members.
    echo "$members" | grep -qx '//' && return 1
    echo "$members" | grep -qx '/' && return 1
    return 0
}

CFLAGS="-target ${TRIPLE} -isysroot ${IOS_SDK} -Os -D__IOS_PROHIBITED= -DLIBPM3 -Wno-error=unused-but-set-variable"
CXXFLAGS="$CFLAGS -std=c++11"
LDFLAGS="-target ${TRIPLE} -isysroot ${IOS_SDK}"

# ── Optionally refresh source ────────────────────────────────────────────────

if [ "$UPDATE_GIT" -eq 1 ] && [ -d "$PM3_SRC/.git" ]; then
    echo "==> Updating Iceman source (--update-pm3-git)..."
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

# ── Pre-build OpenSSL for iOS ─────────────────────────────────────────────────
# Required by mfulc_des_brute helper tool.

OPENSSL_VERSION="3.4.1"
OPENSSL_SRC="$BUILD_DIR/openssl-src"
OPENSSL_INSTALL="$BUILD_DIR/openssl-ios"
OPENSSL_LIB="$OPENSSL_INSTALL/lib/libcrypto.a"

if ! is_apple_archive "$OPENSSL_LIB"; then
    echo "==> Downloading OpenSSL ${OPENSSL_VERSION}..."
    rm -rf "$OPENSSL_SRC" "$OPENSSL_INSTALL"
    curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        -o "$BUILD_DIR/openssl.tar.gz"
    tar -xzf "$BUILD_DIR/openssl.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/openssl-${OPENSSL_VERSION}" "$OPENSSL_SRC"

    echo "==> Building OpenSSL for iOS arm64 (libcrypto only)..."
    (
        cd "$OPENSSL_SRC"
        # Force Apple ar/ranlib — OpenSSL's makefile otherwise picks GNU ar from PATH.
        ./Configure ios64-xcrun \
            --prefix="$OPENSSL_INSTALL" \
            --openssldir="$OPENSSL_INSTALL/ssl" \
            no-shared no-tests no-ui-console no-engine no-async \
            "-isysroot ${IOS_SDK}" \
            "-miphoneos-version-min=${IOS_TARGET}" \
            AR="$IOS_AR" RANLIB="$IOS_RANLIB" CC="$IOS_CC"

        make -j"$(sysctl -n hw.ncpu)" AR="$IOS_AR" RANLIB="$IOS_RANLIB" build_libs
        make AR="$IOS_AR" RANLIB="$IOS_RANLIB" install_dev
    )

    if ! is_apple_archive "$OPENSSL_LIB"; then
        echo "ERROR: $OPENSSL_LIB is not a Mach-O archive Apple ld can link."
        echo "       file says: $(file "$OPENSSL_LIB")"
        echo "       If Homebrew binutils is installed, run: brew unlink binutils"
        echo "       then re-run: $0 --clean"
        exit 1
    fi
fi

# ── Python for iOS (BeeWare Python-Apple-support) ─────────────────────────────

PYTHON_VER="3.13-b14"
PYTHON_MINOR="3.13"
PYTHON_URL="https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_VER}/Python-${PYTHON_MINOR}-iOS-support.b14.tar.gz"
PYTHON_DIR="$BUILD_DIR/python-ios"
PYTHON_XCFRAMEWORK="$SCRIPT_DIR/ProxBuddy/Python.xcframework"
PYTHON_STDLIB_ZIP="$SCRIPT_DIR/ProxBuddy/Resources/python313.zip"
PYTHON_INC_DIR="$PYTHON_XCFRAMEWORK/ios-arm64/Python.framework/Headers"
PYTHON_LIB="$PYTHON_XCFRAMEWORK/ios-arm64/Python.framework/Python"

if [ ! -d "$PYTHON_XCFRAMEWORK" ]; then
    echo "==> Downloading BeeWare Python $PYTHON_VER..."
    mkdir -p "$PYTHON_DIR"
    curl -sL "$PYTHON_URL" -o "$PYTHON_DIR/python.tar.gz"
    tar -xzf "$PYTHON_DIR/python.tar.gz" -C "$PYTHON_DIR"

    echo "==> Installing Python.xcframework..."
    cp -R "$PYTHON_DIR/Python.xcframework" "$PYTHON_XCFRAMEWORK"

    echo "==> Zipping Python standard library..."
    mkdir -p "$SCRIPT_DIR/ProxBuddy/Resources"
    rm -f "$PYTHON_STDLIB_ZIP"
    # Find the stdlib directory — BeeWare layout may vary
    STDLIB_DIR=""
    for candidate in \
        "$PYTHON_DIR/Python.xcframework/ios-arm64/Python.framework/Resources/lib/python${PYTHON_MINOR}" \
        "$PYTHON_DIR/Python.xcframework/lib/python${PYTHON_MINOR}" \
        "$PYTHON_DIR/python-stdlib"; do
        if [ -d "$candidate" ]; then
            STDLIB_DIR="$candidate"
            break
        fi
    done
    if [ -z "$STDLIB_DIR" ]; then
        echo "ERROR: Could not find Python stdlib directory"
        echo "Contents of Python.xcframework:"
        find "$PYTHON_DIR/Python.xcframework" -maxdepth 4 -type d
        exit 1
    fi
    echo "==> Found stdlib at: $STDLIB_DIR"
    (cd "$STDLIB_DIR" && zip -r -q "$PYTHON_STDLIB_ZIP" .)
fi

# Validate Python include dir exists
if [ ! -d "$PYTHON_INC_DIR" ]; then
    echo "ERROR: Python include directory not found at $PYTHON_INC_DIR"
    echo "Listing xcframework contents:"
    find "$PYTHON_XCFRAMEWORK" -maxdepth 4 -type d
    exit 1
fi

# Validate SWIG wrapper exists
if [ ! -f "$PM3_SRC/client/src/pm3_pywrap.c" ]; then
    echo "ERROR: pm3_pywrap.c not found in PM3 source."
    echo "       Run 'make swig' in the PM3 client directory on a machine with SWIG installed,"
    echo "       or ensure you have a recent Iceman checkout."
    exit 1
fi

# ── Apply iOS patch to CMakeLists.txt ─────────────────────────────────────────
# Replaces the fragile sed approach — uses a committed patch file with
# placeholder tokens for Python paths.

echo "==> Applying iOS patch to CMakeLists.txt..."
PATCH_SRC="$SCRIPT_DIR/patches/ios-shared-lib.patch"
PATCH_TMP="$BUILD_DIR/ios-shared-lib.patched"
mkdir -p "$BUILD_DIR"

if [ ! -f "$PATCH_SRC" ]; then
    echo "ERROR: Patch file not found at $PATCH_SRC"
    exit 1
fi

# Substitute Python path placeholders in the patch
sed -e "s|@PYTHON_INC_DIR@|${PYTHON_INC_DIR}|g" \
    -e "s|@PYTHON_LIB@|${PYTHON_LIB}|g" \
    "$PATCH_SRC" > "$PATCH_TMP"

# Apply the patch — will fail loudly if upstream CMakeLists has changed
git -C "$PM3_SRC" apply "$PATCH_TMP"
echo "==> Patch applied successfully."

echo "==> Applying iOS pm3_open no-exit patch..."
git -C "$PM3_SRC" apply "$SCRIPT_DIR/patches/ios-pm3-open-no-exit.patch"
echo "==> pm3_open patch applied."

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

# Verify Python was detected
if ! grep -q "HAVE_PYTHON" cmake-configure.log 2>/dev/null; then
    echo "WARNING: HAVE_PYTHON may not be defined. Check cmake-configure.log."
fi

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

"$IOS_STRIP" "$PM3_BIN" 2>/dev/null \
    || echo "    (strip skipped — may be unsigned or wrong arch)"

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

# These two Lua modules are generated (gitignored in Iceman) by the desktop
# Makefile. CMake declares the rules but does not attach them to the target,
# so an iOS-only build never produces them — and `require('pm3_cmd')` fails.
echo "==> Generating Lua command tables..."
mkdir -p "$PM3_RES_DEST/lualibs"
awk -f "$PM3_SRC/client/pm3_cmd_h2lua.awk" \
    "$PM3_SRC/include/pm3_cmd.h" \
    > "$PM3_RES_DEST/lualibs/pm3_cmd.lua"
awk -f "$PM3_SRC/client/default_keys_dic2lua.awk" \
    "$PM3_SRC/client/dictionaries/mfc_default_keys.dic" \
    > "$PM3_RES_DEST/lualibs/mfc_default_keys.lua"

# ── Install iOS Python shim into pyscripts ────────────────────────────────────
# Copies pm3_resources_ios.py and patches key scripts to use it on iOS.

IOS_SHIM="$SCRIPT_DIR/ProxBuddy/Resources/pyscripts/pm3_resources_ios.py"
if [ -f "$IOS_SHIM" ]; then
    echo "==> Installing iOS Python shim..."
    cp "$IOS_SHIM" "$PM3_RES_DEST/pyscripts/pm3_resources_ios.py"

    # Inject iOS platform check at the top of scripts that use subprocess
    IOS_HEADER='import sys as _sys\nif hasattr(_sys, "implementation") and _sys.platform == "ios":\n    from pm3_resources_ios import find_tool, find_dict, run_tool\n    import subprocess as _sp; _sp.run = run_tool\n'

    for script in fm11rf08s_recovery.py fm11rf08s_full.py mfulc_counterfeit_recovery.py; do
        TARGET="$PM3_RES_DEST/pyscripts/$script"
        if [ -f "$TARGET" ]; then
            # Only inject if not already patched
            if ! grep -q "pm3_resources_ios" "$TARGET" 2>/dev/null; then
                echo "    Patching $script for iOS..."
                printf '%b\n' "$IOS_HEADER" | cat - "$TARGET" > "$TARGET.tmp"
                mv "$TARGET.tmp" "$TARGET"
            fi
        fi
    done
fi

# ── Cross-compile helper tools for iOS ────────────────────────────────────────
# These are standalone C tools that pm3 pyscripts call via subprocess.
# On iOS, subprocess is blocked — so we compile them as dylibs with renamed
# main() entry points. The pm3_resources_ios.py shim loads them via ctypes.

TOOLS_DIR="$PM3_SRC/tools"
COMMON_DIR="$PM3_SRC/common"
TOOLS_OUTPUT="$SCRIPT_DIR/ProxBuddy/Resources/tools"
mkdir -p "$TOOLS_OUTPUT"

TOOL_CFLAGS="$CFLAGS -I$PM3_SRC/include -I$COMMON_DIR"

# Shared source files for staticnested tools (crapto1 + bucketsort + nested_util)
CRYPTO_SRCS=(
    "$COMMON_DIR/crapto1/crypto1.c"
    "$COMMON_DIR/crapto1/crapto1.c"
    "$COMMON_DIR/bucketsort.c"
    "$TOOLS_DIR/mfc/card_only/nested_util.c"
)

echo ""
echo "==> Cross-compiling helper tools..."

for tool in staticnested_1nt staticnested_2nt staticnested_0nt \
            staticnested_2x1nt_rf08s staticnested_2x1nt_rf08s_1key; do
    echo "    Building lib${tool}.dylib..."
    "$IOS_CC" $TOOL_CFLAGS -shared -o "$TOOLS_OUTPUT/lib${tool}.dylib" \
        -Dmain=${tool}_main \
        "$TOOLS_DIR/mfc/card_only/${tool}.c" \
        "${CRYPTO_SRCS[@]}" \
        $LDFLAGS -lpthread 2>&1 || {
        echo "    WARNING: Failed to build $tool — skipping"
        continue
    }
    "$IOS_STRIP" "$TOOLS_OUTPUT/lib${tool}.dylib" 2>/dev/null || true
done

# mfulc_des_brute requires OpenSSL (libcrypto)
if [ -f "$OPENSSL_LIB" ]; then
    echo "    Building libmfulc_des_brute.dylib..."
    "$IOS_CC" $TOOL_CFLAGS -shared -o "$TOOLS_OUTPUT/libmfulc_des_brute.dylib" \
        -Dmain=mfulc_des_brute_main \
        -I"$OPENSSL_INSTALL/include" \
        "$TOOLS_DIR/mfulc_des_brute/mfulc_des_brute.c" \
        $LDFLAGS "$OPENSSL_LIB" -lpthread 2>&1 || {
        echo "    WARNING: Failed to build mfulc_des_brute — skipping"
    }
    "$IOS_STRIP" "$TOOLS_OUTPUT/libmfulc_des_brute.dylib" 2>/dev/null || true
else
    echo "    Skipping mfulc_des_brute — OpenSSL not available"
fi

echo ""
echo "==> Helper tools built:"
ls -lh "$TOOLS_OUTPUT/"*.dylib 2>/dev/null || echo "    (none)"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Done. Binary: $OUTPUT"
echo "==> Build log:    $BUILD_DIR/cmake/build.log"
echo "==> All done!"
