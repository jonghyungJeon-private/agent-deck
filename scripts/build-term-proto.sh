#!/usr/bin/env bash
# 내장 터미널 시제품 ClaudeTerm.app 을 dist/ 에 만든다(기존 ClaudeSessions.app 과 별개).
#   scripts/build-term-proto.sh            # release
#   CONFIG=debug scripts/build-term-proto.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUNDLE_ID="${BUNDLE_ID:-dev.claude-sessions.term}"
swift build -c "$CONFIG" --product ClaudeTermDaemon
swift build -c "$CONFIG" --product ClaudeTerm
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP=dist/ClaudeTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeTerm" "$BIN_DIR/ClaudeTermDaemon" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>ko</string>
	<key>CFBundleExecutable</key><string>ClaudeTerm</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>ClaudeTerm</string>
	<key>CFBundleDisplayName</key><string>Claude Term</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0.1</string>
	<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 터미널 글꼴(JetBrains Mono, OFL / Symbols Nerd Font, MIT) — 앱 안에서만 등록해 쓴다
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
codesign --force --sign - "$APP/Contents/MacOS/ClaudeTermDaemon"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "✔ $APP"
