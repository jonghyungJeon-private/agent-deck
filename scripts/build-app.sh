#!/usr/bin/env bash
# ClaudeSessions.app 을 만들고 배포용 zip 을 dist/ 에 만든다.
#   VERSION=0.2.0 scripts/build-app.sh
#   ARCHS=arm64 scripts/build-app.sh          # 한 아키텍처만(빠름)
#   BUNDLE_ID=com.example.claude-sessions scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-dev.claude-sessions.app}"
ARCHS="${ARCHS:-arm64 x86_64}"

arch_args=()
for arch in $ARCHS; do arch_args+=(--arch "$arch"); done

swift build -c release "${arch_args[@]}" --product ClaudeSessions
BIN_DIR="$(swift build -c release "${arch_args[@]}" --product ClaudeSessions --show-bin-path)"

APP=dist/ClaudeSessions.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeSessions" "$APP/Contents/MacOS/ClaudeSessions"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Developer ID 가 없으므로 ad-hoc 서명(Apple Silicon 에서 실행하려면 최소한 필요).
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

ZIP="dist/ClaudeSessions-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✔ $APP"
echo "✔ $ZIP ($(lipo -archs "$APP/Contents/MacOS/ClaudeSessions"))"
