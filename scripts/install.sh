#!/usr/bin/env bash
# AgentDeck 설치·업데이트·삭제(사내 배포용). Apple Silicon 전용, ad-hoc 서명이라 Gatekeeper 격리 속성을 지우고 설치한다.
#   install.sh                  최신 릴리스를 받아 설치·업데이트(gh 로그인 + 비공개 저장소 권한 필요)
#   install.sh <zip 경로|URL>    그 zip 으로 설치
#   install.sh --uninstall      앱·hook 을 지우고, 데이터 폴더는 물어본 뒤 지운다
# 동료용 한 줄(README):
#   gh api repos/<REPO>/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash
#   gh api repos/<REPO>/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash -s -- --uninstall
# 시험용 환경 변수(실제 /Applications·설정을 건드리지 않게):
#   AGENTDECK_APPS_DIR=<폴더>  설치·삭제할 앱 폴더  |  AGENTDECK_NO_OPEN=1  설치 뒤 열지 않음
#   HOME·CLAUDE_CONFIG_DIR·CODEX_HOME·AGENTDECK_HOME·AGENTDECK_TERM_HOME(예전 이름 CLAUDE_SESSIONS_HOME·CLAUDE_TERM_HOME)은
#   앱과 같은 뜻으로 따른다
set -euo pipefail

# 릴리스를 올리는 저장소(owner/repo). 바꾸면 Sources/SessionCore/UpdateCheck.swift 의 repository 와 README 도 같이.
REPO="jonghyungJeon-private/agent-deck"
# 0.4 부터 안쪽 이름도 AgentDeck(실행 파일 AgentDeck·AgentDeckDaemon, 묶음 ID dev.agentdeck.app, 데이터 폴더 AgentDeck).
# 예전 이름(ClaudeTerm.app, 실행 파일 ClaudeTerm·ClaudeTermDaemon, dev.claude-sessions.term, 데이터 ClaudeSessions)도 찾아서 다룬다.
APP_NAME="AgentDeck.app"
OLD_APP_NAME="ClaudeTerm.app"
BUNDLE_ID="dev.agentdeck.app"
OLD_BUNDLE_ID="dev.claude-sessions.term"
APP_EXES="AgentDeck|ClaudeTerm"
DAEMON_EXES="AgentDeckDaemon|ClaudeTermDaemon"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# 파일로 실행했으면 stdin 에서, `… | bash` 로 실행했으면(stdin 이 스크립트) 터미널에서 답을 읽는다. 읽을 곳이 없으면 N.
ask() {
  local answer="" echo=1
  printf '%s [y/N] ' "$1"
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    [[ -t 0 ]] && echo=0
    read -r answer || true
  elif { exec 3</dev/tty; } 2>/dev/null; then
    echo=0
    read -r answer <&3 || true
    exec 3<&-
  fi
  # 터미널에서 친 답은 이미 화면에 있다. 아니면(파일·답 없음) 줄을 맞춰 남긴다.
  if ((echo)); then printf '%s\n' "$answer"; fi
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]]
}

# 앱 폴더: 시험용 지정 → 없으면 /Applications 와 ~/Applications 둘 다 본다
if [[ -n "${AGENTDECK_APPS_DIR:-}" ]]; then
  APP_DIRS=("$AGENTDECK_APPS_DIR")
else
  APP_DIRS=("/Applications" "$HOME/Applications")
fi

# 설치된 앱(새 이름·예전 이름)
installed_apps() {
  local dir name
  for dir in "${APP_DIRS[@]}"; do
    for name in "$APP_NAME" "$OLD_APP_NAME"; do
      [[ -d "$dir/$name" ]] && printf '%s\n' "$dir/$name"
    done
  done
  return 0
}

regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$(){}?+|/]/\\&/g'; }

# 이 폴더들의 앱에서 뜬 프로세스(앱 또는 데몬, 새·예전 이름). 다른 곳(개발 빌드 등)에서 뜬 것은 건드리지 않는다.
# $1 은 실행 파일 이름 정규식(예: "$APP_EXES"). 데몬은 앱이 띄울 때 붙인 인자(--root <폴더>)가 있을 수 있다.
pids_of() {
  local exe="$1" dirs="" dir
  for dir in "${APP_DIRS[@]}"; do dirs+="${dirs:+|}$(regex_escape "$dir")"; done
  pgrep -f "^($dirs)/(AgentDeck|ClaudeTerm)\\.app/Contents/MacOS/($exe)( --root .*)?\$" 2>/dev/null || true
}

# 앱만 끈다(저장 안 한 편집기가 있으면 앱이 묻는다). 셸·claude 는 데몬이 붙잡고 있어 끊기지 않는다.
quit_app() {
  [[ -n "$(pids_of "$APP_EXES")" ]] || return 0
  local id
  for id in "$BUNDLE_ID" "$OLD_BUNDLE_ID"; do
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  done
  local i
  for i in $(seq 1 20); do
    [[ -z "$(pids_of "$APP_EXES")" ]] && return 0
    sleep 0.5
  done
  die "앱이 종료되지 않았습니다. AgentDeck 을 직접 종료한 뒤 다시 실행하세요."
}

check_mac() {
  # Rosetta 로 띄운 터미널은 uname -m 이 x86_64 라서 하드웨어도 본다
  if [[ "$(uname -m)" != arm64 && "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]]; then
    die "AgentDeck 은 Apple Silicon(M1 이상) Mac 전용입니다. 이 Mac($(uname -m))에는 설치할 수 없습니다."
  fi
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 13 )) || die "macOS 13 이상이 필요합니다(지금 $(sw_vers -productVersion))."
}

find_gh() {
  local candidate
  for candidate in "$(command -v gh 2>/dev/null || true)" /opt/homebrew/bin/gh /usr/local/bin/gh; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# 최신 릴리스 zip 을 $1 폴더로 받는다
download_latest() {
  local gh
  gh="$(find_gh)" || die "GitHub CLI(gh)가 필요합니다. 터미널에서: brew install gh && gh auth login"
  "$gh" auth status >/dev/null 2>&1 || die "gh 에 로그인돼 있지 않습니다. 터미널에서: gh auth login"
  say "→ $REPO 최신 릴리스를 받는 중…" >&2
  if ! "$gh" release download --repo "$REPO" --pattern 'AgentDeck-*.zip' --dir "$1" 2>"$1/gh.err"; then
    if ! "$gh" api "repos/$REPO" >/dev/null 2>&1; then
      die "저장소 $REPO 에 접근할 수 없습니다. 관리자에게 collaborator 초대를 요청하고, GitHub 알림·메일에서 초대를 수락한 뒤 다시 실행하세요(gh 로그인 계정: $("$gh" api user --jq .login 2>/dev/null || echo '?'))."
    fi
    die "릴리스를 받지 못했습니다: $(head -n1 "$1/gh.err")"
  fi
  local zip
  zip="$(ls "$1"/AgentDeck-*.zip 2>/dev/null | head -n1)"
  [[ -n "$zip" ]] || die "릴리스에 AgentDeck-*.zip 이 없습니다."
  printf '%s' "$zip"
}

install_app() {
  check_mac
  local tmp src zip app
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  tmp="$TMP_DIR"
  src="${1:-}"
  if [[ -z "$src" ]]; then
    zip="$(download_latest "$tmp")"
  elif [[ "$src" == http://* || "$src" == https://* ]]; then
    curl -fL --progress-bar "$src" -o "$tmp/app.zip" || die "내려받지 못했습니다: $src"
    zip="$tmp/app.zip"
  else
    [[ -f "$src" ]] || die "파일이 없습니다: $src"
    zip="$src"
  fi
  ditto -x -k "$zip" "$tmp/unzipped" || die "zip 을 풀지 못했습니다: $zip"
  app="$tmp/unzipped/$APP_NAME"
  [[ -d "$app" ]] || app="$tmp/unzipped/$OLD_APP_NAME" # 0.1 zip
  [[ -d "$app" ]] || die "zip 안에 $APP_NAME 이 없습니다."

  # /Applications 에 쓸 수 없는 계정(표준 사용자 등)은 ~/Applications 에 설치한다
  local apps="${APP_DIRS[0]}"
  if [[ ! -w "$apps" ]]; then apps="$HOME/Applications"; fi
  mkdir -p "$apps"
  local dest="$apps/$APP_NAME"

  # 새 앱을 먼저 옆에 완전히 복사·확인한 뒤 바꿔 끼운다(복사가 실패해도 기존 앱과 hook 경로는 그대로)
  local stage="$apps/.$APP_NAME.new"
  rm -rf "$stage"
  ditto "$app" "$stage"
  xattr -dr com.apple.quarantine "$stage" 2>/dev/null || true
  [[ -x "$stage/Contents/MacOS/AgentDeck" || -x "$stage/Contents/MacOS/ClaudeTerm" ]] || { rm -rf "$stage"; die "복사한 앱이 올바르지 않습니다."; }
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/Contents/Info.plist" 2>/dev/null || echo '?')"

  # 실행 중이면 앱만 끄고 바꾼다. 셸·claude 는 데몬이 붙잡고 있어 끊기지 않는다.
  quit_app

  if [[ -e "$dest" ]]; then
    local old="$apps/.$APP_NAME.old"
    rm -rf "$old"
    mv "$dest" "$old"
    mv "$stage" "$dest" || { mv "$old" "$dest"; die "교체 실패 — 기존 앱을 되돌렸습니다."; }
    rm -rf "$old"
  else
    mv "$stage" "$dest"
  fi

  # 예전 이름(ClaudeTerm.app)으로 깔린 것은 지운다. 이미 떠 있는 예전 데몬·세션은 그대로 돌고,
  # 새 앱이 그 데몬에 붙어 예전 데이터 폴더를 쓴다(그 데몬이 끝나면 앱이 데이터를 새 폴더로 옮긴다).
  local migrated="" previous
  while IFS= read -r previous; do
    [[ "$previous" == */"$OLD_APP_NAME" ]] || continue
    rm -rf "$previous" && migrated="$previous"
  done < <(installed_apps)

  [[ "${AGENTDECK_NO_OPEN:-}" == 1 ]] || open "$dest"
  say "✔ AgentDeck v$version 설치 완료: $dest"
  if [[ -n "$migrated" ]]; then
    say "  예전 ClaudeTerm($migrated)을 AgentDeck 으로 바꿨습니다. 열린 세션은 그대로입니다."
    say "  사이드바 아래 '갱신하기' 를 누르면 Claude Code hook 이 새 위치를 가리킵니다(누르기 전까지 claude 에 hook 오류가 보일 수 있습니다)."
  elif [[ -n "$(pids_of ClaudeTermDaemon)" ]]; then
    say "  예전 판의 세션 데몬이 돌고 있어 열린 세션은 그대로 이어집니다(상태 줄에 '이전 데몬에서 실행 중')."
    say "  사이드바 아래 '갱신하기' 를 눌러 Claude Code hook 을 새 이름(AgentDeckDaemon)으로 바꾸세요."
  else
    say "  처음이면 사이드바 아래 '연결하기' 를 눌러 Claude Code hook 을 넣으세요(세션 이름·되살리기·상태 표시·알림에 필요)."
  fi
}

# --- 삭제 ---

claude_settings() { printf '%s/settings.json' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
codex_hooks() { printf '%s/hooks.json' "${CODEX_HOME:-$HOME/.codex}"; }

# 앱 바이너리 없이 hook 빼기(앱이 이미 없을 때). python3 가 없으면(명령줄 도구 미설치) 손으로 지우는 방법을 알린다.
unhook_with_python() {
  if ! xcode-select -p >/dev/null 2>&1 && [[ "$(command -v python3 2>/dev/null)" == /usr/bin/python3 || -z "$(command -v python3 2>/dev/null)" ]]; then
    return 1
  fi
  python3 -I - "$(claude_settings)" hook "$(codex_hooks)" codex-hook <<'PY'
import json, os, shutil, sys, time
args = sys.argv[1:]
failed = False
for path, sub in zip(args[0::2], args[1::2]):
    label = "Claude Code" if sub == "hook" else "Codex"
    if not os.path.exists(path):
        print(f"{label}: {path} 이 없습니다"); continue
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        data = json.loads(text) if text.strip() else {}
        assert isinstance(data, dict)
    except Exception as e:
        print(f"{label}: {path} 를 읽지 못해 그대로 둡니다 — {e}"); failed = True; continue
    names = ["AgentDeckDaemon", "ClaudeTermDaemon"] + (["ClaudeSessions"] if sub == "hook" else [])
    suffixes = tuple(f'{n}" {sub}' for n in names)
    hooks = data.get("hooks") if isinstance(data.get("hooks"), dict) else {}
    removed = 0
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list): continue
        kept_groups = []
        for group in groups:
            inner = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(inner, list):
                kept_groups.append(group); continue
            kept = [h for h in inner if not (isinstance(h, dict) and str(h.get("command", "")).endswith(suffixes))]
            removed += len(inner) - len(kept)
            if kept:
                group["hooks"] = kept; kept_groups.append(group)
        if kept_groups: hooks[event] = kept_groups
        else: del hooks[event]
    if removed == 0:
        print(f"{label}: {path} 에 이 앱의 hook 이 없습니다"); continue
    if hooks: data["hooks"] = hooks
    else: data.pop("hooks", None)
    backup = f"{path}.agentdeck-backup-{time.strftime('%Y%m%d-%H%M%S')}"
    n = 1
    while os.path.exists(backup):
        n += 1; backup = f"{path}.agentdeck-backup-{time.strftime('%Y%m%d-%H%M%S')}-{n}"
    shutil.copy2(path, backup)
    tmp = path + ".agentdeck-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True); f.write("\n")
    os.replace(tmp, path)
    print(f"{label}: {path} 에서 hook {removed}개를 뺐습니다 (백업: {backup})")
sys.exit(1 if failed else 0)
PY
}

unhook() {
  local app daemon rc
  while IFS= read -r app; do
    daemon="$app/Contents/MacOS/AgentDeckDaemon"
    [[ -x "$daemon" ]] || daemon="$app/Contents/MacOS/ClaudeTermDaemon" # 예전 판(예전 이름만 뺀다)
    [[ -x "$daemon" ]] || continue
    "$daemon" unhook --claude-settings "$(claude_settings)" --codex-hooks "$(codex_hooks)" && rc=0 || rc=$?
    (( rc == 0 )) && return 0
    (( rc == 1 )) && break # 설정 파일을 읽지 못함 — 다른 방법으로도 같으니 손으로 고치게 안내
  done < <(installed_apps)
  if [[ "${rc:-}" != 1 ]]; then
    unhook_with_python && return 0
  fi
  say "! hook 을 자동으로 빼지 못했습니다. 아래 파일에서 command 가 'AgentDeckDaemon\" hook'·'ClaudeTermDaemon\" hook'(Codex 는 'codex-hook')으로 끝나는 항목을 지우세요:"
  say "    $(claude_settings)"
  say "    $(codex_hooks)"
  say "  (앱을 지운 뒤에도 0.2 이후 hook 은 아무것도 하지 않고 끝나므로 급하지 않습니다)"
}

uninstall_app() {
  local apps=() app
  while IFS= read -r app; do apps+=("$app"); done < <(installed_apps)
  local daemons
  daemons="$(pids_of "$DAEMON_EXES" | tr '\n' ' ')"
  # 데이터 폴더: 지정(AGENTDECK_HOME, 예전 CLAUDE_SESSIONS_HOME)이 있으면 그것만, 아니면 새 폴더와 예전 폴더 둘 다
  local datas=() data
  if [[ -n "${AGENTDECK_HOME:-${CLAUDE_SESSIONS_HOME:-}}" ]]; then
    datas=("${AGENTDECK_HOME:-$CLAUDE_SESSIONS_HOME}")
  else
    local base="${AGENTDECK_APP_SUPPORT:-$HOME/Library/Application Support}"
    datas=("$base/AgentDeck" "$base/ClaudeSessions")
  fi
  local term_home="${AGENTDECK_TERM_HOME:-${CLAUDE_TERM_HOME:-}}"

  say "AgentDeck 을 삭제합니다."
  if ((${#apps[@]})); then for app in "${apps[@]}"; do say "  - 앱: $app"; done; else say "  - 설치된 앱 없음(hook 만 정리)"; fi
  say "  - Claude Code·Codex 설정에서 이 앱의 hook(AgentDeckDaemon, 예전 이름 ClaudeTermDaemon 포함)만 뺍니다(다른 hook 은 그대로, 백업을 남김)"
  ask "계속할까요?" || { say "취소했습니다."; exit 0; }

  if [[ -n "${daemons// /}" ]]; then
    say "! 세션 데몬이 실행 중입니다(pid ${daemons% }). 끄면 이 앱에서 연 셸·claude·codex 세션이 모두 종료됩니다."
    say "  (claude 대화는 남아 있어 다른 터미널에서 claude --resume 으로 이어 열 수 있습니다)"
    ask "세션을 종료하고 계속할까요?" || { say "취소했습니다. 세션을 정리한 뒤 다시 실행하세요."; exit 0; }
  fi

  quit_app
  unhook
  if [[ -n "${daemons// /}" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $daemons 2>/dev/null || true
    sleep 1
    # shellcheck disable=SC2086
    kill -KILL $daemons 2>/dev/null || true
    say "✔ 세션 데몬을 껐습니다"
  fi
  if ((${#apps[@]})); then
    for app in "${apps[@]}"; do rm -rf "$app" && say "✔ 지움: $app"; done
  fi

  for data in "${datas[@]}"; do
    [[ -d "$data" ]] || continue
    say ""
    say "데이터 폴더: $data"
    say "  (세션 기록·이름·탭 배치·spaces 순서)"
    if [[ "$(basename "$data")" == ClaudeSessions ]]; then
      say "  (예전 이름의 폴더입니다. 옮긴 뒤면 표식 파일만 남아 있을 수 있습니다)"
      [[ -d /Applications/ClaudeSessions.app ]] && say "  ! 예전 ClaudeSessions 앱이 아직 있습니다 — 그 앱의 기록도 함께 지워집니다."
    fi
    if ask "이 데이터 폴더를 지울까요?"; then
      rm -rf "$data"
      say "✔ 지움: $data"
    else
      say "  남겨 두었습니다(다시 설치하면 이어서 씁니다)."
    fi
  done
  [[ -n "$term_home" && -d "$term_home" ]] && ask "데몬 폴더($term_home)도 지울까요?" && rm -rf "$term_home"
  local id
  for id in "$BUNDLE_ID" "$OLD_BUNDLE_ID"; do
    rm -f "$HOME/Library/Preferences/$id.plist"
    rm -rf "$HOME/Library/Saved Application State/$id.savedState"
  done
  say ""
  say "✔ 삭제 완료. settings.json 백업(*.agentdeck-backup-*, 예전 *.claudeterm-backup-*)은 남겨 두었습니다. 필요 없으면 지워도 됩니다."
}

case "${1:-}" in
  --uninstall) uninstall_app ;;
  -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true ;;
  *) install_app "${1:-}" ;;
esac
