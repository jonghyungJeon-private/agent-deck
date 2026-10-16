#!/usr/bin/env bash
# ClaudeTerm.app 을 dist/ 에 만들고, 배포용 zip(dist/ClaudeTerm-<버전>.zip)도 만든다.
#   scripts/build-term-proto.sh                    # release
#   VERSION=0.2.0 scripts/build-term-proto.sh
#   CONFIG=debug scripts/build-term-proto.sh
# 동료 설치: scripts/install.sh dist/ClaudeTerm-<버전>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
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
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
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
# Markdown 미리보기 변환기(marked, MIT) — 앱 안에서만 쓰고 실행 중에 네트워크에서 받지 않는다
mkdir -p "$APP/Contents/Resources/Markdown"
cp Resources/Markdown/marked.umd.js Resources/Markdown/LICENSE "$APP/Contents/Resources/Markdown/"
codesign --force --sign - "$APP/Contents/MacOS/ClaudeTermDaemon"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
ZIP="dist/ClaudeTerm-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✔ $APP"
echo "✔ $ZIP"
