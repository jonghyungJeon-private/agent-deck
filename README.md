# Claude Sessions

재부팅하거나 터미널 앱을 다시 켜도 **열려 있던 Claude Code 세션을 메뉴바에서 클릭 한 번으로 이어 여는** macOS 앱.

- 목록: **실행 중**은 터미널(Ghostty·iTerm2…)별 → 프로젝트(git 저장소)별, **꺼짐**은 프로젝트별로 묶어 보여줌
- 실행 중인 세션: 클릭하면 그 세션이 돌고 있는 터미널의 탭으로 이동
- 꺼진 세션(창 닫기·앱 종료·재부팅): 클릭하면 터미널 **새 탭**에서 `claude --resume <id>` 로 이어 열기
- 세션 제목(Claude 자동 제목 / `-n` 이름), 폴더·브랜치, 마지막 요청을 보여줌

- **모두 열기 (배치 유지)**: 꺼진 세션을 원래 창·탭·분할 배치대로 한 번에 연다
  - 배치는 **터미널마다 따로** 기록한다(`layout-iterm2.json`, `layout-ghostty.json`). 창이 여러 개면 창마다 기록한다.
  - 15초마다 지금 배치로 갱신하되, 통째로 닫힌 창의 기록은 남겨 둔다(창을 하나씩 닫거나 터미널을 끄는 도중이어도 자리를 잃지 않는다).
  - 같은 창·탭의 세션이 아직 열려 있으면(예: 분할 A|B 중 A 만 닫음) 새 창 대신 **그 옆을 나눠** 붙이고, 탭이 통째로 닫혔으면 그 창에 새 탭으로 연다(iTerm2).
- **중복 실행 방지**: 열기 직전에 claude 프로세스를 다시 확인한다. 이미 떠 있는 세션, 방금 열라고 보낸 세션(claude 가 뜰 때까지 최대 45초)은 다시 열지 않는다.
  연속 클릭, 앱과 명령줄 동시 실행도 같은 잠금을 쓴다. 목록에는 주황색 "여는 중…"으로 보인다.
- 빈 화면 판단: 그 화면(tty)에 셸 말고 다른 프로그램(claude, vim, ssh, 서버 등)이 하나라도 돌면 그 화면에는 입력하지 않는다.

지원 터미널(설정에서 선택):

| | 새 탭으로 열기 | 탭 찾기 | 배치 기록 | 되살린 빈 창 채우기 |
|---|---|---|---|---|
| iTerm2 3.5+ | ✔ | tty 로 정확히 | tty 로 정확히 | ✔ (같은 모양 창이 있으면) |
| Ghostty 1.3+ | ✔ | 화면 제목으로 | 화면 제목으로(같은 제목이 여럿이면 비워 둠) | 꺼둠 — 항상 새 창에 배치를 만든다 (아래 참고) |

Ghostty 는 화면별 tty 를 알려주지 않아 Claude 가 바꾸는 화면 제목("✳ 세션 제목")으로 짝짓는다. 같은 제목의 화면·세션이 여럿이면 자리를 바꿔 기록할 수 있어 짝짓지 않는다.
Ghostty 가 되살린 빈 셸에 명령을 입력하는 기능은 시험 중 Ghostty 가 멈춘 일이 있어(2026-10-13) 원인을 확인할 때까지 꺼 두었다.
분할 방향은 두 터미널 모두 알려주지 않으므로 새 창에 다시 만들 때는 설정의 "분할 방향"을 쓴다.
요구 사항: macOS 13+, Claude Code.

## 설치 (사내)

```bash
scripts/install.sh <ClaudeSessions-x.y.z.zip 경로 또는 URL>
```

서명되지 않은 앱이라 스크립트가 격리 속성(quarantine)을 지우고 `/Applications` 에 넣는다(쓸 수 없는 계정이면 `~/Applications`).
새 앱을 옆에 다 복사한 뒤 바꿔 끼우므로, 중간에 실패해도 기존 앱과 hook 경로는 그대로다.
zip 을 브라우저로 받아 직접 열면 macOS 가 막으니 스크립트를 쓴다.

처음 실행하면:
1. 앱을 열면 세션 목록 창이 뜬다 → **Claude Code 연결** (창은 메뉴바 아이콘이나 앱을 다시 열어 불러올 수 있다. 아이콘이 노치에 가려질 수 있음)
   `~/.claude/settings.json` 에 SessionStart / SessionEnd hook 이 추가된다(기존 설정 유지, `settings.json.bak-claude-sessions-*` 백업).
   이미 열려 있던 세션 중 실행 인자에 세션 ID 가 있는 것은 바로 가져온다.
2. 세션을 처음 열 때 "ClaudeSessions 가 Ghostty 를 제어하려고 합니다" → **허용**
3. (권장) 설정 → **로그인 시 자동 실행**

## 동작 방식

```
claude 시작 ── SessionStart hook ──▶ ~/Library/Application Support/ClaudeSessions/sessions/<id>.json
/exit · Ctrl-D · /clear ── SessionEnd ──▶ 기록 삭제
창 닫기 · 앱 종료 ── SessionEnd(other) ──▶ 기록 유지(꺼짐)
재부팅 ── (hook 없음) ──▶ 기록 유지, claude 프로세스가 없으니 꺼짐
```

- 같은 세션을 두 화면에서 열었다가 하나만 닫으면, 남은 claude 로 기록을 옮긴다(hook 또는 앱의 5초 새로 고침).
- 기록 파일은 앱·명령줄·여러 hook 이 동시에 고쳐도 서로 덮어쓰지 않게 잠금(`sessions/.lock`) 안에서 바꾼다.
- iTerm2 는 앱을 강제 종료해도 세션 프로세스를 살려 두었다가 다시 켤 때 붙인다. 이때 세션은 "실행 중"으로 남고 다시 열지 않는다.

- 실행 중 여부는 기록한 claude PID + 프로세스 시작 시각으로 판단한다(PID 재사용 구분).
- `claude -p` 같은 비대화형 실행, 터미널 없이 뜬 세션(SDK·IDE)은 기록하지 않는다.
- 제목·마지막 요청은 `~/.claude/projects/**/<id>.jsonl` 의 `ai-title` / `custom-title` / `last-prompt` 에서 읽는다.
- 꺼진 세션은 설정한 보관 기간(기본 14일)이 지나면 목록에서 정리된다.

## 설정

| 항목 | 기본값 | 설명 |
|---|---|---|
| 꺼진 세션 열 곳 | 세션이 돌던 터미널 | "항상 위 터미널"로 바꾸면 Ghostty 세션도 설정한 터미널(예: iTerm2)에 같은 배치로 연다 |
| 실행 명령 | `claude --resume {id}` | 새 탭의 셸에 입력된다. `{id}` `{name}` `{cwd}` 사용 가능(셸 인용 처리됨, 따옴표로 감쌀 필요 없음) |
| 권한 확인 건너뛰기 | 꺼짐 | 켜면 명령 끝에 `--dangerously-skip-permissions` 를 붙인다. 세션 우클릭 → "권한 확인 없이 이어 열기" 로 한 번만 쓸 수도 있다 |
| 분할 방향 | 좌우 | 모두 열기에서 새 창에 분할을 다시 만들 때 |
| 꺼진 세션 보관 | 14일 | |
| Dock 에 표시 | 켜짐 | 끄면 메뉴바 전용 |
| 로그인 시 자동 실행 | 꺼짐 | |

Dock 아이콘을 누르거나 앱을 다시 열면 세션 목록 창이 뜬다. 아이콘은 `scripts/make-icon.swift` 로 다시 그릴 수 있다.

## 명령줄

```bash
ClaudeSessions.app/Contents/MacOS/ClaudeSessions list         # 기록 목록 (● 실행 중 / ◐ 여는 중 / ○ 꺼짐)
ClaudeSessions.app/Contents/MacOS/ClaudeSessions refresh      # 앱의 새로 고침과 같은 정리 후 목록
ClaudeSessions.app/Contents/MacOS/ClaudeSessions open <id>    # 터미널 새 탭에서 이어 열기(이미 열려 있으면 거절)
ClaudeSessions.app/Contents/MacOS/ClaudeSessions restore-all  # 꺼진 세션을 기록된 배치대로 모두 열기
ClaudeSessions.app/Contents/MacOS/ClaudeSessions layout [--save]  # 터미널별 지금 배치·화면별 세션·기록된 배치(진단용)
ClaudeSessions.app/Contents/MacOS/ClaudeSessions focus <id>   # 실행 중 세션의 탭으로 이동
ClaudeSessions.app/Contents/MacOS/ClaudeSessions hook         # (Claude Code hook 용)
```

## 제거

설정 → **연결 해제** (hook 제거) 후 앱 삭제. 기록은 `~/Library/Application Support/ClaudeSessions` 에 있다.

## 개발

```bash
swift build && swift test
scripts/build-app.sh                 # dist/ClaudeSessions.app, dist/ClaudeSessions-<버전>.zip (universal)
VERSION=0.2.0 ARCHS=arm64 scripts/build-app.sh
```

`CLAUDE_SESSIONS_HOME=<폴더>` 로 기록 위치를 바꿔 실제 기록과 분리해 테스트할 수 있다.

알려진 한계:
- 분할 방향·비율은 터미널이 알려주지 않아 새로 만들 때는 설정의 방향으로 차례로 나눈다(2×2 같은 혼합 배치는 근사). 살아 있는 화면 옆에 붙일 때도 오른쪽(아래)에 붙는다.
- `CLAUDE_CONFIG_DIR` 로 Claude 설정 폴더를 바꾼 경우는 아직 지원하지 않는다(항상 `~/.claude`).

### 구조

- `Sources/SessionCore` — hook 처리, 기록 저장소, settings.json 병합, 대화 파일 요약, 프로세스 정보
- `Sources/ClaudeSessions` — 메뉴바 UI, 설정 창, 터미널 연동(`TerminalLauncher`; 터미널 추가 시 여기에 구현 추가)
- `Sources/TermWire`, `Sources/CPTY`, `Sources/ClaudeTermDaemon`, `Sources/ClaudeTerm` — 내장 터미널 시제품(아래)

## 내장 터미널 시제품 (ClaudeTerm)

외부 터미널 대신 앱 안에 터미널을 두는 실험. 왼쪽은 세션 목록, 오른쪽은 터미널(SwiftTerm).
기존 ClaudeSessions.app 과 별개 앱이며 배포 대상이 아니다.

```bash
scripts/build-term-proto.sh          # dist/ClaudeTerm.app
open dist/ClaudeTerm.app
```

- 셸·claude 는 앱이 아니라 `ClaudeTermDaemon` 이 붙잡고 있다. 앱을 끄거나 다시 빌드해도 계속 돌고, 앱을 다시 켜면 그대로 붙는다.
  데몬은 화면도 앱 연결도 없이 60초가 지나면 스스로 끝난다. 재부팅하면 셸·claude 는 끝난다.
- 메모리: 앱은 지금 탭에 보이는 화면만 터미널 뷰를 만든다(다른 탭은 데몬이 화면당 최대 2MB 의 지난 출력만 보관).
  그래서 탭이 늘어도 앱 메모리는 거의 그대로다(화면 6개로 나눈 탭도 약 76MB). 실측(M 시리즈, release): 앱 빈 상태 28MB, 화면 보는 중 약 62~65MB(뒤로 보기 2,000줄), 데몬 3~9MB.
  글자가 화면에 찍히는 동안(입력·claude 작업 중)은 macOS 가 그리기용 그래픽 메모리를 약 +130MB 붙였다가, 멈추고 몇 초 뒤 돌려준다.
  창 크기·그리기 방식(Metal 포함)과 무관하고, 빈 창 하나만 띄운 시험 앱이나 iTerm2 도 똑같다(시스템 동작, 새는 것 아님).
- 화면 ↔ 세션 짝짓기: 데몬이 화면의 tty 를 정확히 알고, hook 기록의 tty 와 맞춘다(추측 없음). 셸에는 `TERM_PROGRAM=ClaudeTerm`, `CLAUDE_SESSIONS_PANE=<화면 ID>` 가 들어간다.
- 모양: Ghostty 기본값과 같게 — JetBrains Mono 13pt + Nerd Font 아이콘(`Resources/Fonts`, 앱 안에서만 등록), 배경 #282c34·Tomorrow Night 색, 늘 보이는 스크롤 막대.
  한글은 D2Coding(설치돼 있으면, 다음은 나눔고딕코딩, 없으면 Apple SD Gothic Neo)으로, Ghostty 처럼 소문자 높이를 JetBrains Mono 에 맞춰 그린다.
- Shift+Enter = 줄바꿈(⌥+Enter 와 같은 ESC CR 을 보낸다).
- 되살리기: 화면마다 지금 폴더·claude 세션·claude 실행 옵션(세션 지정 인자 뺀 것, 예: `--dangerously-skip-permissions`)을 배치와 함께 저장한다.
  데몬이 바뀌면(강제 종료·재부팅 뒤 새로 뜸) 사라진 화면을 지우지 않고 "꺼짐"(속 빈 점)으로 남기고, 그 탭을 열 때
  같은 자리·같은 ID 로 셸을 다시 띄워 `claude --resume <세션>` 을 원래 옵션으로 실행한다(대화가 없던 세션·셸은 셸만).
  한꺼번에 다 띄우지 않아 가볍다. 같은 데몬에서 셸·claude 가 스스로 끝난 화면은 Ghostty 처럼 닫힌다.
- Claude Code hook(SessionStart·SessionEnd)은 ClaudeTerm 이 직접 맡는다(`ClaudeTermDaemon hook`, AppKit 없이 가볍게 끝남).
  연결이 안 됐거나 예전 ClaudeSessions 앱 hook 이면 사이드바 아래에 안내와 "연결하기/옮기기" 버튼이 뜬다.
  누를 때만 `~/.claude/settings.json` 을 고치고(백업을 남김), 예전 ClaudeSessions hook 은 같이 뺀다. 세션 기록 위치는 그대로.
- 되살릴 때 이어받는 claude 옵션은 허용 목록(권한·모델·effort·add-dir·MCP·허용 도구 등)만. 처음 질문·`--worktree`·세션 지정은 뺀다.
- 지난 출력을 다시 그리는 동안 터미널이 내는 응답·클립보드 쓰기는 버린다(예전 질의의 답이 지금 claude 입력으로 새지 않게).
- 데몬이 바뀌었는지는 데몬 실행마다 새로 정하는 ID 로 본다(PID 재사용 오판 방지). 만들기·되살리기가 15초 안에 안 되면
  되살리던 화면은 "꺼짐"으로 돌아가고(30초 뒤 다시 시도), 새로 만들던 화면은 빠진다.
- 하위 에이전트(Agent 도구): claude 와 하위 에이전트는 메인 폴더에서 돌고 작업 트리는 경로로만 쓰므로, 하위 에이전트 기록
  (`~/.claude/projects/<폴더>/<세션>/subagents/agent-*.jsonl`) 끝부분에 가장 많이 나온 작업 트리에 그 에이전트를 붙인다.
  작업 트리 줄에 "● 작업 중 N"과 에이전트(설명·종류·띄운 세션)가 보이고, 누르면 띄운 claude 화면으로 넘어가며 마지막 메시지를 펼친다.
  claude 안의 에이전트 화면으로 바로 바꾸는 공식 방법은 없어(키 입력 흉내는 입력 중인 글과 섞일 위험) 띄운 화면으로만 옮긴다.
  가볍게: 10초에 한 번, 최근 15분 안에 바뀐 파일만 끝 64KB 를 바이트로 찾고, 크기가 그대로면 다시 읽지 않는다(실측 첫 훑기 8ms, 이후 1ms).
- 화면 ↔ 세션 짝짓기는 claude 프로세스의 부모를 따라 올라가 화면의 셸을 찾는다(Kiro CLI 처럼 셸을 가상 터미널로 한 겹
  감싸는 도구가 있어도 맞게). 못 찾으면 tty 로 짝짓는다.
- 탭·분할은 Ghostty 처럼 좌우·위아래로 자유롭게 나눈다. 배치는 `term/layout.json` 에 저장돼 앱을 껐다 켜도 그대로다.
  어느 탭에도 없는 화면(예: `ctl new` 로 만든 것)은 새 탭으로 붙는다. 사이에 틈을 끌어 크기를 바꾼다.
  단축키(Ghostty 기본값, 한글 입력 중에도 키 위치로 동작):
  ⌘T 새 탭 · ⌘D 오른쪽으로 나누기 · ⌘⇧D 아래로 나누기 · ⌘W 화면 닫기(셸이 아닌 프로그램이 돌면 묻는다) · ⌘⌥W 탭 닫기 ·
  ⌘[ ⌘] 이전/다음 화면 · ⌘⌥방향키 그쪽 화면으로 · ⌘⇧↩ 화면 크게 보기/되돌리기 · ⌘⌃= 크기 같게 · ⌘⌃방향키 나눈 선 옮기기 ·
  ⌘⇧[ ⌘⇧] 또는 ⌃Tab ⌃⇧Tab 이전/다음 탭 · ⌘1~8 탭, ⌘9 마지막 탭. 새 탭·분할은 지금 화면의 폴더에서 열린다.
- 이름은 한 규칙으로 정해 탭·왼쪽 목록·분할 테두리에 똑같이 쓴다(앞의 것이 있으면 그것):
  ① 이 앱에서 직접 바꾼 이름(탭 두 번 클릭, 탭·목록 오른쪽 클릭, 셸 메뉴 > 이름 바꾸기 — 비우면 자동 이름으로)
  ② 사람이 붙인 claude 세션 이름(/rename, `claude -n`). claudec 처럼 `<폴더>@<브랜치>`·`<폴더>-<HHMM>` 로 기계적으로 붙인 이름은 건너뛴다
  ③ claude 가 스스로 붙인 제목(ai-title) ④ 첫 질문으로 지은 제목(Orca 처럼) ⑤ 폴더 이름.
  ④ 는 세션마다 한 번 `claude -p --model sonnet`(설정·hook·MCP·도구·대화 저장 없이, 약 3초)으로 짓고 `term/names.json` 에 둔다.
  짓는 동안은 첫 질문 앞부분을 보여 준다. `CLAUDE_TERM_AUTO_TITLE=0` 이면 부르지 않는다. 실패 이유는 `term/title-errors.log`.
  claude 세션 자체의 이름(`claude --resume` 목록)은 바꾸지 않는다.
- 화면 모양은 herdr 를 참고했다: 어두운 사이드바·탭 줄에 고정폭 글꼴, 나눈 화면마다 테두리와 제목, 포커스 화면은 보라색 테두리.
- 왼쪽 목록은 폴더(git 저장소)별로 묶고, 저장소의 작업 트리(worktree)를 아래에 펼친다(claude 가 만든 `.claude/worktrees/` 는 주황 아이콘).
  화면의 폴더는 claude 가 돌면 claude 프로세스의, 아니면 셸의 지금 폴더를 따른다(작업 트리로 옮겨 가면 그 아래로 옮겨진다).
  git 을 실행하지 않고 `.git` 파일만 읽는다. 폴더·작업 트리 줄의 `+`·오른쪽 클릭으로 그 자리에서 claude·셸을 새 탭으로 연다.
- 스크롤: 바뀌지 않은 줄은 지난번 그린 결과를 다시 써서 한 번 그리기가 약 1/3 로 줄었다(PATCHES.md).
- 터미널 엔진은 한글 폭·입력 표시를 고친 SwiftTerm 사본(`Vendor/SwiftTerm`, 고친 내용은 `PATCHES.md`).
- 데이터 위치: `~/Library/Application Support/ClaudeSessions/term/`(소켓·로그). `CLAUDE_TERM_HOME` 으로 바꿀 수 있다.
- 진단: `dist/ClaudeTerm.app/Contents/MacOS/ClaudeTermDaemon ctl list | new <cwd> [명령] | send <id> <글> | dump <id> | kill <id>`
- 시험용: `CLAUDE_TERM_SNAPSHOT=<폴더>` 면 1초마다 창 그림(window.png)과 터미널 그림(terminal.png, 실제 배경색)을 남기고,
  `CLAUDE_TERM_DEBUG=1` 이면 분산 알림으로 화면 고르기·메뉴 동작(`action split-right` 등)·입력·단축키(`chord cmd+shift+d`)·
  틈 끌기(`drag`)·스크롤 속도(`scroll <픽셀> <횟수>`)·줄 캐시 검사(`verify-cache`)·한글 조합 시험을 받는다(그림 저장은 메모리를 더 쓰니 측정 땐 끈다).
  실제 창은 `screencapture -l <창 번호>` 로 찍을 수 있다(층 그림은 SwiftUI·글자가 빠지는 일이 있다).

아직 없는 것: 상태 표시(작업 중·입력 대기·완료)와 알림, 글꼴·색 설정.
