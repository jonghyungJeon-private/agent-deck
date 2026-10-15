# Claude Term

Claude Code 세션을 위한 가벼운 터미널 앱(macOS, 사내 배포용·서명 없음).
왼쪽은 폴더(git 저장소)·작업 트리별로 묶은 세션 목록, 오른쪽은 Ghostty 식 탭·분할 터미널이다.
셸과 claude 는 앱이 아니라 백그라운드 데몬이 붙잡고 있어서 앱을 끄거나 업데이트해도 세션이 계속 돌고,
데몬까지 꺼져도(강제 종료·재부팅) 탭을 열면 `claude --resume` 으로 같은 자리에 되살린다.

목표는 "목록·상태·표시·알림 + 터미널 + 세션 유지"만, 최대한 가볍게. 편집기·파일 트리·diff·브라우저는 넣지 않는다.
(예전 메뉴바 앱 ClaudeSessions 는 이 앱으로 대체되어 코드에서 뺐다. 세션 기록 위치 `~/Library/Application Support/ClaudeSessions/` 는 그대로 쓴다.)

## 설치 (사내)

```bash
scripts/install.sh dist/ClaudeTerm-0.1.0.zip      # 또는 사내 저장소 URL
```

- `/Applications`(쓸 수 없으면 `~/Applications`)에 설치하고 Gatekeeper 격리 속성을 지운다. 실행 중이면 바꿔 끼운다(세션은 유지).
- 처음 열면 사이드바 아래 **연결하기** 를 눌러 Claude Code hook 을 넣는다(세션 이름·되살리기·상태 표시에 필요).
  예전 ClaudeSessions 를 쓰던 PC 는 **ClaudeTerm 으로 옮기기** 가 뜨며, 누르면 그 hook 을 이 앱 것으로 바꾼다(설정 백업을 남김).

## 개발

```bash
swift build && swift test
scripts/build-term-proto.sh                     # dist/ClaudeTerm.app + dist/ClaudeTerm-<버전>.zip
VERSION=0.2.0 scripts/build-term-proto.sh
```

- 시험은 실제 기록·데몬과 분리해서: `CLAUDE_TERM_HOME=<폴더> CLAUDE_SESSIONS_HOME=<폴더>`.
- 구조: `Sources/ClaudeTerm`(앱), `Sources/ClaudeTermDaemon`(PTY 를 붙잡는 데몬, `hook`·`ctl` 명령), `Sources/TermWire`(앱↔데몬 메시지),
  `Sources/TermLayout`(탭·분할·되살리기 정보, 작업 트리 읽기), `Sources/SessionCore`(hook 처리·세션 기록·대화 파일 읽기·프로세스 정보),
  `Sources/CPTY`(forkpty), `Vendor/SwiftTerm`(고친 터미널 엔진, `PATCHES.md`).

## 자세한 동작

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
- Claude Code hook(SessionStart·SessionEnd 와 작업 상태용 hook — 아래 "작업 상태 표시와 알림")은 ClaudeTerm 이 직접 맡는다(`ClaudeTermDaemon hook`, AppKit 없이 가볍게 끝남).
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

## 작업 상태 표시와 알림

claude 화면마다 지금 무엇을 하는지를 왼쪽 목록(점 + "입력 대기 · 권한 요청" 같은 글), 묶음 점(안의 가장 급한 상태),
탭 제목 앞 점(탭 안 화면 중 가장 급한 상태), 분할 테두리 제목 앞("입력 대기 · <이름>")에 보인다. 색만으로 구분하지 않게 글·모양도 다르다.

| 상태 | 색·모양 | 언제 (Claude Code hook) |
|---|---|---|
| 작업 중 | 노랑 점 | `UserPromptSubmit`(질문을 보냄) |
| 입력 대기 | 빨강 테두리 점, 안 보는 탭은 붉은 바탕 + 아래 줄 | `PermissionRequest`(권한 요청), `Notification` 의 `permission_prompt`·`elicitation_dialog`·`elicitation_url_dialog`·`agent_needs_input` |
| 완료 | 청록 점 | `Stop`(응답을 마침). 그 화면을 보면(앱이 앞에 있을 때) "쉬는 중"으로 바뀐다 |
| 오류 | 빨강 점 | `StopFailure`(API 오류 등, 오류 종류를 함께 보임) |
| 쉬는 중 | 초록 속 빈 점 | 완료를 확인했거나 `Notification` 의 `idle_prompt`(입력 없이 약 60초) |

- hook 은 세션 기록 파일(`sessions/<세션>.json`)에 `state`·`stateAt`·`stateMessage`·`pane`·`stateSeq`(상태를 적을 때마다 오르는 번호 — 같은 초 안의 변화도 구분해 알림이 빠지지 않게. 날짜 형식은 예전 빌드와 같다)를 적고, 앱은 2초마다 목록을 다시 만들며 읽는다.
  화면 짝짓기는 hook 이 적은 화면 ID(`pane`)가 먼저다.
- 알림: 입력 대기·완료·오류로 바뀌면 macOS 알림을 보낸다(누르면 그 화면으로). 지금 보고 있는 화면, 앱을 켠 직후 이미 그 상태였던 화면은 알리지 않는다.
  Dock 아이콘 배지에 확인이 필요한 화면 수가 뜬다. `CLAUDE_TERM_NO_NOTIFY=1` 이면 알림을 보내지 않는다(시험용).
- **기존 사용자는 사이드바 아래 "갱신하기"를 한 번 눌러야 한다.** 예전 연결(SessionStart·SessionEnd 만)으로는 상태 hook 이 없어
  claude 화면이 상태 없이 claude 색 점으로만 보인다. 갱신은 그 뒤 새로 시작하는(또는 다시 연) claude 세션부터 적용된다.
- 알려진 한계:
  - Esc 로 중단하면 `Stop` 이 오지 않아 "작업 중"으로 남는다. 약 60초 뒤 `idle_prompt` 가 와서 "쉬는 중"으로 바로잡힌다.
  - 권한 요청 `Notification` 은 늦게 올 수 있어 `PermissionRequest` 로 바로 "입력 대기"로 바꾼다. 허락한 뒤에는 따로 오는 hook 이 없어,
    "입력 대기" 시각보다 2초 넘게 뒤에 대화 파일이 늘면 다시 일하는 것으로 보고 "작업 중"으로 바꾼다(추정).
  - "완료 → 쉬는 중"은 앱이 앞에 있고 그 화면을 고르고 있을 때만 바뀐다.

아직 없는 것: 글꼴·색 설정.
