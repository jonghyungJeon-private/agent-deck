#!/usr/bin/env bash
# AgentDeck.app 을 dist/ 에 만들고, 배포용 zip(dist/AgentDeck-<버전>.zip)도 만든다. Apple Silicon(arm64) 전용, ad-hoc 서명.
#   scripts/build-term-proto.sh                    # release
#   VERSION=0.3.0 scripts/build-term-proto.sh
#   CONFIG=debug scripts/build-term-proto.sh
# 동료 설치: scripts/install.sh dist/AgentDeck-<버전>.zip (릴리스에 올린 뒤에는 인자 없이 — README 참고)
# 실행 파일 AgentDeck·AgentDeckDaemon, 묶음 ID dev.agentdeck.app, 데이터 ~/Library/Application Support/AgentDeck
# (0.3 까지는 ClaudeTerm·ClaudeTermDaemon·dev.claude-sessions.term·ClaudeSessions — 앱이 예전 데몬·데이터를 이어받는다).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.4.2}"
[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon(arm64) 에서 빌드하세요" >&2; exit 1; }
BUNDLE_ID="${BUNDLE_ID:-dev.agentdeck.app}"
swift build -j 2 -c "$CONFIG" --product AgentDeckDaemon
swift build -j 2 -c "$CONFIG" --product AgentDeck
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP=dist/AgentDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentDeck" "$BIN_DIR/AgentDeckDaemon" "$APP/Contents/MacOS/"
# 예전 이름 → 새 데몬. 이미 떠 있던 claude 세션은 시작할 때 읽은 hook 명령(…/ClaudeTermDaemon hook)을 계속 쓰므로,
# 업데이트 뒤에도 그 세션들의 상태 기록이 끊기지 않게 둔다(새 hook 은 AgentDeckDaemon 을 가리킨다). 나중 판에서 뺀다.
ln -s AgentDeckDaemon "$APP/Contents/MacOS/ClaudeTermDaemon"
for bin in AgentDeck AgentDeckDaemon; do
  [[ "$(lipo -archs "$APP/Contents/MacOS/$bin")" == arm64 ]] || { echo "$bin 이 arm64 가 아닙니다" >&2; exit 1; }
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>ko</string>
	<key>CFBundleExecutable</key><string>AgentDeck</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>AgentDeck</string>
	<key>CFBundleDisplayName</key><string>AgentDeck</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSArchitecturePriority</key><array><string>arm64</string></array>
	<key>NSHumanReadableCopyright</key><string>사내 배포용</string>
</dict>
</plist>
PLIST
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 글꼴(JetBrains Mono·D2Coding, OFL / Symbols Nerd Font, MIT) — 앱 안에서만 등록해 쓴다(Resources/Fonts/README.md)
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# SwiftTerm 의 선택형 Metal renderer 가 읽는 셰이더.
cp -R "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
# Markdown 미리보기 변환기(marked, MIT) — 앱 안에서만 쓰고 실행 중에 네트워크에서 받지 않는다
mkdir -p "$APP/Contents/Resources/Markdown"
cp Resources/Markdown/marked.umd.js Resources/Markdown/LICENSE "$APP/Contents/Resources/Markdown/"
codesign --force --sign - "$APP/Contents/MacOS/AgentDeckDaemon"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
ZIP="dist/AgentDeck-$VERSION.zip"
rm -f "$ZIP"
# 확장 속성(._ 파일)은 빼고 묶는다 — 서명은 실행 파일·_CodeSignature 안에 있다
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "✔ $APP"
echo "✔ $ZIP"
