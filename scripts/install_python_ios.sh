#!/bin/bash
# Xcode Run Script: stage BeeWare stdlib into the .app and rewrite .so → frameworks.
#
# Do not call BeeWare's install_python() — it shells out to rsync with already-
# absolute paths, and Xcode 16+/26 wraps rsync and prefixes SRCROOT again.
# ditto is not wrapped and copies the same trees.
set -euo pipefail

: "${PROJECT_DIR:?}"
: "${CODESIGNING_FOLDER_PATH:?}"
: "${EFFECTIVE_PLATFORM_NAME:?}"
: "${ARCHS:?}"

XC_REL="ProxBuddy/Python.xcframework"
XC="$PROJECT_DIR/$XC_REL"
UTILS="$XC/build/utils.sh"

if [ ! -f "$UTILS" ]; then
    echo "error: Python.xcframework is missing at $XC"
    echo "Run ./build_pm3_ios.sh <path/to/proxmark3> then xcodegen generate, and rebuild."
    exit 1
fi

if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
    if [ -d "$XC/ios-arm64-simulator" ]; then
        SLICE="ios-arm64-simulator"
    else
        SLICE="ios-arm64_x86_64-simulator"
    fi
elif [ "$EFFECTIVE_PLATFORM_NAME" = "-iphoneos" ]; then
    SLICE="ios-arm64"
else
    echo "error: unsupported EFFECTIVE_PLATFORM_NAME=$EFFECTIVE_PLATFORM_NAME"
    exit 1
fi

DEST="$CODESIGNING_FOLDER_PATH/python/lib"
mkdir -p "$DEST"

copy_tree() {
    local src="$1"
    if [ ! -d "$src" ]; then
        echo "error: expected Python files at $src"
        echo "Listing $XC:"
        ls -la "$XC" || true
        echo "Run: rm -rf \"$XC\" && ./build_pm3_ios.sh <path/to/proxmark3>"
        exit 1
    fi
    echo "Copying $src -> $DEST"
    /usr/bin/ditto "$src" "$DEST"
}

if [ -d "$XC/lib" ]; then
    copy_tree "$XC/lib"
    for arch in $ARCHS; do
        if [ -d "$XC/$SLICE/lib-$arch" ]; then
            copy_tree "$XC/$SLICE/lib-$arch"
        fi
    done
else
    copy_tree "$XC/$SLICE/lib"
fi

rm -f "$DEST"/libpython*.dylib

PYTHON_VER="$(ls -1 "$DEST" | grep -E '^python3\.[0-9]+$' | head -1 || true)"
if [ -z "$PYTHON_VER" ]; then
    echo "error: no python3.X directory in $DEST"
    ls -la "$DEST"
    exit 1
fi

echo "Install Python $PYTHON_VER extension modules..."
# shellcheck disable=SC1090
source "$UTILS"
process_dylibs "$XC_REL" "python/lib/$PYTHON_VER/lib-dynload"

SITECUSTOMIZE="$PROJECT_DIR/ProxBuddy/Resources/sitecustomize.py"
if [ -f "$SITECUSTOMIZE" ]; then
    cp "$SITECUSTOMIZE" "$DEST/$PYTHON_VER/sitecustomize.py"
fi
