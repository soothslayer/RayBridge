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
# Always assemble a fresh bundle. macOS may add Finder metadata after the app
# has been launched, and that metadata prevents a later code-signing pass.
if [[ "$APP" != "$PWD/build/RayBridge.app" ]]; then
  echo "Refusing to remove an unexpected app path: $APP"
  exit 1
fi
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/app"
swiftc mac/RayBridge.swift -o "$APP/Contents/MacOS/RayBridge" -framework AppKit -framework Carbon -framework WebKit
cp -L "$NODE_BIN" "$APP/Contents/Resources/runtime/node"
cp -L "$CODEX_BIN" "$APP/Contents/Resources/runtime/codex"
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
<key>CFBundleVersion</key><string>2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Let your paired iPhone connect to the RayBridge assistant.</string>
<key>NSAppleEventsUsageDescription</key><string>Let spoken RayBridge requests control only the Mac apps you approve.</string>
</dict></plist>
PLIST
# Explicitly re-sign copied executables before sealing the app. Current macOS
# can reject a nested executable that retains a different Developer ID even
# when a recursive verification of the outer development bundle succeeds.
codesign --force --sign - "$APP/Contents/Resources/runtime/node"
codesign --force --sign - "$APP/Contents/Resources/runtime/codex"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "This is a local development build for this Mac architecture, not a notarized distribution."
