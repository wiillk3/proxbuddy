#!/bin/bash
# setup.sh — Generate the ProxBuddy Xcode project
# Requires: Homebrew, Xcode 26+
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Checking for XcodeGen..."
if ! command -v xcodegen &>/dev/null; then
    echo "==> Installing XcodeGen via Homebrew..."
    brew install xcodegen
fi

echo "==> Generating ProxBuddy.xcodeproj..."
xcodegen generate --spec project.yml

echo ""
echo "Done. Open ProxBuddy.xcodeproj in Xcode 26."
echo ""
echo "Next steps:"
echo "  1. Set your Team ID in Signing & Capabilities"
echo "  2. Run build_pm3_ios.sh to cross-compile pm3client"
echo "  3. Build and sideload via AltStore or direct install"
