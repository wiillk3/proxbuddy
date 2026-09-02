#!/bin/bash
# Wrap a Mach-O dylib as a shallow iOS .framework so App Store processing
# does not treat Frameworks/*.dylib as Swift stdlib (ITMS-90426).
set -euo pipefail

usage() {
    echo "usage: $0 <libfoo.dylib> [more.dylib ...]" >&2
    exit 1
}

[[ $# -ge 1 ]] || usage

wrap_one() {
    local src="$1"
    [[ -f "$src" ]] || { echo "error: missing $src" >&2; exit 1; }

    local dir name dest binary bundle_id
    dir="$(cd "$(dirname "$src")" && pwd)"
    name="$(basename "$src" .dylib)"
    dest="$dir/${name}.framework"
    binary="$dest/$name"
    # CFBundleIdentifier allows only [A-Za-z0-9.-] — underscores are rejected.
    bundle_id="spot.rfid.proxbuddy.$(echo "$name" | tr '_' '-')"

    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$src" "$binary"
    chmod +x "$binary"

    codesign --remove-signature "$binary" 2>/dev/null || true
    install_name_tool -id "@rpath/${name}.framework/${name}" "$binary" 2>/dev/null || true

    cat > "$dest/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${name}</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${name}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>26.0</string>
</dict>
</plist>
EOF
    local privacy
    privacy="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/OpenSSL.xcprivacy"
    if [[ -f "$privacy" ]] && grep -a -q -E 'OpenSSL|BoringSSL' "$binary"; then
        cp "$privacy" "$dest/PrivacyInfo.xcprivacy"
        echo "    OpenSSL privacy manifest -> $dest"
    fi
    echo "    wrapped $src -> $dest"
}

for f in "$@"; do
    wrap_one "$f"
done
