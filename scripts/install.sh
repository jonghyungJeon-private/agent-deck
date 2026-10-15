#!/usr/bin/env bash
# 사내 배포용 설치 스크립트. 서명되지 않은 앱이라 Gatekeeper 격리 속성을 지우고 설치한다.
#   scripts/install.sh dist/ClaudeSessions-0.1.0.zip
#   scripts/install.sh https://<사내 저장소>/ClaudeSessions-0.1.0.zip
set -euo pipefail

SRC="${1:?사용: install.sh <zip 경로 또는 URL>}"
# /Applications 에 쓸 수 없는 계정(표준 사용자 등)은 ~/Applications 에 설치한다
APPS="/Applications"
[[ -w "$APPS" ]] || { APPS="$HOME/Applications"; mkdir -p "$APPS"; }
DEST="$APPS/ClaudeSessions.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "$SRC" == http://* || "$SRC" == https://* ]]; then
  curl -fL --progress-bar "$SRC" -o "$TMP/app.zip"
else
  cp "$SRC" "$TMP/app.zip"
fi
ditto -x -k "$TMP/app.zip" "$TMP/unzipped"
[[ -d "$TMP/unzipped/ClaudeSessions.app" ]] || { echo "zip 안에 ClaudeSessions.app 이 없습니다" >&2; exit 1; }

# 새 앱을 먼저 옆에 완전히 복사·확인한 뒤 바꿔 끼운다(복사가 실패해도 기존 앱과 hook 경로는 그대로)
STAGE="$APPS/.ClaudeSessions.app.new"
rm -rf "$STAGE"
ditto "$TMP/unzipped/ClaudeSessions.app" "$STAGE"
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
[[ -x "$STAGE/Contents/MacOS/ClaudeSessions" ]] || { rm -rf "$STAGE"; echo "복사한 앱이 올바르지 않습니다" >&2; exit 1; }

# 실행 중이면 끄고 교체(이 위치의 앱만)
osascript -e 'tell application id "dev.claude-sessions.app" to quit' >/dev/null 2>&1 || true
pkill -f "^$DEST/Contents/MacOS/ClaudeSessions" >/dev/null 2>&1 || true
sleep 1

if [[ -e "$DEST" ]]; then
  OLD="$APPS/.ClaudeSessions.app.old"
  rm -rf "$OLD"
  mv "$DEST" "$OLD"
  mv "$STAGE" "$DEST" || { mv "$OLD" "$DEST"; echo "교체 실패 — 기존 앱을 되돌렸습니다" >&2; exit 1; }
  rm -rf "$OLD"
else
  mv "$STAGE" "$DEST"
fi

open "$DEST"
echo "✔ 설치 완료: $DEST"
echo "  세션 목록 창의 'Claude Code 연결' 을 눌러 시작하세요. (창을 닫아도 메뉴바 아이콘이나 앱 다시 열기로 불러올 수 있음)"
