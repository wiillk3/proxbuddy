#!/bin/bash
# setup.sh — Cross-compile the iOS pm3 client, then generate the Xcode project.
#
# Order matters: build_pm3_ios.sh must run before xcodegen. This script does
# both, in that order. Args are forwarded to build_pm3_ios.sh:
#
#   ./setup.sh [path/to/proxmark3] [--clean] [--update-pm3-git]
#
# Requires: Homebrew, Xcode 26+
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Cross-compiling iOS pm3 client..."
"$SCRIPT_DIR/build_pm3_ios.sh" "$@"

echo "==> Checking for XcodeGen..."
if ! command -v xcodegen &>/dev/null; then
    echo "==> Installing XcodeGen via Homebrew..."
    brew install xcodegen
fi

echo "==> Generating ProxBuddy.xcodeproj..."
xcodegen generate --spec project.yml

echo ""
echo "Done. Open ProxBuddy.xcodeproj in Xcode 26."
echo "Set your Team under Signing & Capabilities, then build."
