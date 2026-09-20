#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/RayBridge.app"
NODE_BIN="$(command -v node)"
CODEX_BIN="$(command -v codex)"
if ! file "$CODEX_BIN" | /usr/bin/grep -q 'Mach-O'; then
  echo "Use a standalone native Codex binary for bundling. Set PATH to its bin directory."
  exit 1
fi
npm ci --omit=dev
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/app"
swiftc mac/RayBridge.swift -o "$APP/Contents/MacOS/RayBridge" -framework AppKit -framework WebKit
# Homebrew ships these read-only, so a copy of one cannot be overwritten on a
# later build. Clear the previous payload instead of copying over it.
rm -rf "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/app"
mkdir -p "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/app"
cp -L "$NODE_BIN" "$APP/Contents/Resources/runtime/node"
cp -L "$CODEX_BIN" "$APP/Contents/Resources/runtime/codex"
chmod u+w "$APP/Contents/Resources/runtime/node" "$APP/Contents/Resources/runtime/codex"
# A Homebrew node is a small launcher that loads libnode from @rpath. Copy that
# library next to the binary so the bundle resolves it; the remaining Homebrew
# dependencies keep their absolute paths, which is fine for a local build.
for lib in $(otool -L "$APP/Contents/Resources/runtime/node" | /usr/bin/awk '/@rpath\/libnode/ {print $1}'); do
  cp -L "$(dirname "$NODE_BIN")/../lib/${lib#@rpath/}" "$APP/Contents/Resources/runtime/${lib#@rpath/}"
  chmod u+w "$APP/Contents/Resources/runtime/${lib#@rpath/}"
done
cp -R bridge node_modules package.json "$APP/Contents/Resources/app/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RayBridge</string>
<key>CFBundleIdentifier</key><string>org.raybridge.mac</string>
<key>CFBundleName</key><string>RayBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Let your paired iPhone connect to the RayBridge assistant.</string>
</dict></plist>
PLIST
# Explicitly re-sign copied executables before sealing the app. Current macOS
# can reject a nested executable that retains a different Developer ID even
# when a recursive verification of the outer development bundle succeeds.
for lib in "$APP/Contents/Resources/runtime/"*.dylib; do
  [ -e "$lib" ] && codesign --force --sign - "$lib"
done
codesign --force --sign - "$APP/Contents/Resources/runtime/node"
codesign --force --sign - "$APP/Contents/Resources/runtime/codex"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "This is a local development build for this Mac architecture, not a notarized distribution."
