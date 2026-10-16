# Claude Term

Claude Code·Codex CLI 세션을 위한 가벼운 터미널 앱(macOS, 사내 배포용·서명 없음).
왼쪽은 폴더(git 저장소)·작업 트리별로 묶은 세션 목록, 오른쪽은 Ghostty 식 탭·분할 터미널이다.
셸과 claude 는 앱이 아니라 백그라운드 데몬이 붙잡고 있어서 앱을 끄거나 업데이트해도 세션이 계속 돌고,
데몬까지 꺼져도(강제 종료·재부팅) 탭을 열면 `claude --resume` 으로 같은 자리에 되살린다.

목표는 "목록·상태·표시·알림 + 터미널 + 세션 유지", 최대한 가볍게. 파일 트리는 IntelliJ 식 도구 창(files)으로 보일 때만 일한다.
가벼운 편집기(IDE 아님 — 자동 완성·리팩터링·LSP 없음, 이름 단위 코드 이동 ⌘B·⌥F7·⌘O 만)가 터미널과 같은 탭·분할에 열린다. diff 보기·브라우저는 아직 없다.
(예전 메뉴바 앱 ClaudeSessions 는 이 앱으로 대체되어 코드에서 뺐다. 세션 기록 위치 `~/Library/Application Support/ClaudeSessions/` 는 그대로 쓴다.)

## Codex CLI

- 사이드바의 **+ codex**(좁은 사이드바에서는 **+ 새 세션 → Codex**)와 폴더·작업 트리의 오른쪽 클릭 메뉴에서 실행한다.
- 실행 중인 대화형 Codex만 화면의 셸 계보로 찾는다. `exec`·`app-server`·node 래퍼는 세션으로 세지 않는다.
- `CODEX_THREAD_ID`와 `CLAUDE_SESSIONS_PANE`, 훅 기록, 명시적인 `codex resume <UUID>` 인자로 세션을 연결한다. 폴더가 같다는 이유로 최근 대화를 연결하지 않는다.
  확인된 연결은 Codex PID·시작 시각과 함께 `term/codex-bindings.json`에 저장한다. 연결 전에도 프로그램명 **codex**는 표시된다.
- Codex의 `state_5.sqlite`·`thread_history_1.sqlite`와 기존 `sessions/**/*.jsonl`을 읽기 전용으로 읽어 이름·작업 상태를 표시한다.
  `CODEX_HOME`을 지정한 CLI는 해당 폴더를 읽는다. 이름 변경은 앱 내부 이름만 바꾼다. Codex 대화·설정·DB는 수정하지 않는다.
- 탭·분할 제목, 폴더·작업 트리 묶음, 작업 상태 점, 완료 확인·알림·Dock 배지에도 반영한다.
  Codex 하위 에이전트는 부모 세션과 연결해 표시하고, 작업 폴더가 작업 트리와 일치하면 그 아래에 둔다.
- **Codex 연결하기**는 `~/.codex/hooks.json`에 관찰용 훅을 추가한다(기존 설정 백업·다른 훅 보존).
  Codex의 **`/hooks`에서 새 훅을 검토·신뢰해야** 권한 요청·질문 대기·완료 상태를 정확하게 받을 수 있다.
  훅은 `ClaudeTermDaemon codex-hook`으로 기록만 남기며, 승인 결정·모델 문맥은 반환하지 않는다.
  연결 전에 실행한 세션은 도구 실행 등에서 세션 ID가 확인된 뒤 이름·복원 정보가 연결될 수 있다.
- 데몬 재시작·재부팅으로 사라진 Codex 화면은 저장된 정확한 ID로 `codex resume <UUID>`를 실행한다.
  모델·프로필·권한 등의 원래 옵션과 `CODEX_HOME`을 이어받고, 첫 질문·`--last`·`--worktree`는 다시 실행하지 않는다.
  예전 Claude 전용 배치 파일도 그대로 읽는다.

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
  `Sources/TermLayout`(탭·분할·되살리기 정보, 작업 트리 읽기), `Sources/EditorCore`(편집기의 화면 없는 부분: 줄 diff·줄 끝·바이너리 판별·안전한 저장·글자 색 훑기·선언 찾기·이름 맞추기·이동 기록), `Sources/SessionCore`(hook 처리·세션 기록·대화 파일 읽기·프로세스 정보),
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
- 지난 출력은 앞에서부터 잘리므로 긴 claude 세션은 맨 앞의 대체 화면 켜기(`ESC[?1049h`)가 사라진다. 그대로 다시 그리면
  claude 화면이 보통 화면에 남고 `/exit` 뒤 "Resume this session with:" 가 그 위에 겹쳐 보였다.
  - 데몬: 버리는 바이트만 모드 추적기(`TermWire/TerminalModeTracker`)에 먹여, 남은 출력이 시작하는 시점의 모드
    (대체 화면, 커서 숨김, DECCKM, bracketed paste, 마우스·포커스, kitty 키보드 스택)를 기억하고, 붙을 때 기본값과 다른 것만
    앞에 붙여 보낸다(동기 출력 2026 은 빼고). 데몬이 새로 떠야 적용된다(지금 돌고 있는 데몬의 세션은 그대로).
  - 앱(예전 데몬에도 통하는 대비책): 지난 출력에서 처음 만나는 대체 화면 켜기·끄기가 끄기면 먼저 켜고 그린다.
    하나도 없으면 "대체 화면 상태 모름"으로 표시해, 대체 화면이 아닌데 끄기가 오면 화면을 지우고 맨 위에서 이어 간다(PATCHES.md).
  - 시험용 스위치: 데몬 `CLAUDE_TERM_NO_MODE_PREFIX=1`(앞 모드 안 붙임 = 예전 데몬 흉내), 앱 `CLAUDE_TERM_NO_ALT_FALLBACK=1`(대비책 끔).
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
  ⌘[ ⌘] 이전/다음 화면(편집기 화면에선 뒤로/앞으로 — 아래 "코드 이동") · ⌘⌥방향키 그쪽 화면으로 · ⌘⇧↩ 화면 크게 보기/되돌리기 · ⌘⌃= 크기 같게 · ⌘⌃방향키 나눈 선 옮기기 ·
  ⌘⇧[ ⌘⇧] 또는 ⌃Tab ⌃⇧Tab 이전/다음 탭 · ⌘1~8 탭, ⌘9 마지막 탭. 새 탭·분할은 지금 화면의 폴더에서 열린다.
- 이름은 한 규칙으로 정해 탭·왼쪽 목록·분할 테두리에 똑같이 쓴다(앞의 것이 있으면 그것):
  ① 이 앱에서 직접 바꾼 이름(탭 두 번 클릭, 탭·목록 오른쪽 클릭, 셸 메뉴 > 이름 바꾸기 — 비우면 자동 이름으로)
  ② 사람이 붙인 claude 세션 이름(/rename, `claude -n`). claudec 처럼 `<폴더>@<브랜치>`·`<폴더>-<HHMM>` 로 기계적으로 붙인 이름은 건너뛴다
  ③ claude 가 스스로 붙인 제목(ai-title) ④ 첫 질문으로 지은 제목(Orca 처럼) ⑤ 폴더 이름.
  ④ 는 세션마다 한 번 `claude -p --model sonnet`(설정·hook·MCP·도구·대화 저장 없이, 약 3초)으로 짓고 `term/names.json` 에 둔다.
  짓는 동안은 첫 질문 앞부분을 보여 준다. `CLAUDE_TERM_AUTO_TITLE=0` 이면 부르지 않는다. 실패 이유는 `term/title-errors.log`.
  claude 세션 자체의 이름(`claude --resume` 목록)은 바꾸지 않는다.
- 도구 창(IntelliJ 식): 창 = [왼쪽 도크 | 터미널 | 오른쪽 도크]. 도구는 **spaces**(세션 목록)와 **files**(파일 트리) 둘이고,
  각각 왼쪽·오른쪽·숨김 중 한 곳에 붙는다. 한 도크에 둘이 붙으면 위에 도구 버튼 줄(고른 것은 강조색)이 생기고, 보이는 도구가 없는 도크는 접힌다.
  도구 버튼·머리 줄 오른쪽 클릭 = 왼쪽으로/오른쪽으로 옮기기·숨기기. 보기 메뉴에도 있다.
  ⌘⇧E files, ⌘⇧S spaces: 숨김이면 마지막 쪽에 보이고 고름 → 보이지만 안 골랐으면 고름 → 고른 상태면 숨김(한글 입력 중에도 키 위치로).
  ⌘⇧E 로 열면 트리에 포커스가 가고, Esc 는 터미널로 돌아간다.
  기본값은 spaces·files 둘 다 왼쪽, spaces 를 고른 채로(IntelliJ 의 Project 창 자리, 터미널 폭은 그대로). 배치·고른 도구·도크 폭은 `term/ui.json`
  (없거나 예전·망가진 파일이면 기본값).
- files: 포커스 화면의 작업 트리 맨 위(작업 트리가 아니면 화면 폴더)를 보인다. 머리 줄에 폴더 이름·브랜치·바뀐 파일 수, 오른쪽에 모두 접기.
  다른 프로젝트 화면으로 포커스가 옮겨 가면 루트가 바뀌고, 펼친 폴더는 루트별로 메모리에만 기억한다(루트 12개·루트당 400개까지).
  NSOutlineView 로 그리고, 폴더는 펼칠 때 백그라운드에서 읽는다(`.git`·`.DS_Store` 뺌, 폴더 먼저 → 대소문자 무시 이름순, 점 파일은 흐리게).
  두 번 클릭·Enter = 편집기로 열기(아래). 오른쪽 클릭: (파일이면) 오른쪽에 나눠 열기·아래에 나눠 열기, Finder 에서 보기·경로 복사·상대 경로 복사·여기서 셸 열기(새 탭).
  편집기 화면이 포커스면 그 파일의 작업 트리 맨 위를 보인다.
- 편집기: files 에서 두 번 클릭·Enter 하면 지금 탭 바로 뒤 새 탭에 열고, 이미 열린 파일이면 그 화면으로 간다(나눠 열기도 같음).
  - 터미널과 같은 탭·분할에 들어간다(배치 잎 ID `editor:<UUID>`). 데몬과 상관없어 데몬 목록 맞추기에서 지워지지 않고 셸로 되살리지도 않으며,
    spaces 목록에 나오지 않는다. 연 파일·커서 위치는 `term/layout.json`(`editors`)에 저장돼 앱을 다시 켜면 다시 열린다.
  - 탭·분할 테두리 제목 = 파일 이름, 저장 안 했으면 뒤에 ●. 아래 상태 줄에 줄:열·UTF-8·줄 끝(LF/CRLF)·언어.
  - 단축키: ⌘S 저장(파일 메뉴, 키 위치로 받아 한글 입력 중에도 — ⌘⇧S 는 그대로 spaces), ⌘F 찾기 막대·⌥⌘F 바꾸기·⌘G/⌘⇧G 다음/이전,
    ⌘Z/⌘⇧Z 되돌리기(문서마다 따로, 탭을 옮겨도 이어짐), ⌘X 잘라내기. 찾기·되돌리기·잘라내기는 편집기에서만 켜져 터미널의 키는 그대로 터미널로 간다.
    ⌘W·⌘D·크게 보기 등 화면 단축키는 편집기에도 그대로(⌘W 는 편집기만 닫음, ⌘[ ⌘] 는 뒤로/앞으로). Enter 는 윗줄 들여쓰기를 잇는다. 줄바꿈 없음(가로 스크롤).
  - 코드 이동(IntelliJ 식, LSP 없이 이름 단위 — 가볍게). 메뉴 **이동**에도 있다. 단축키는 키 위치로 받아 한글 입력 중에도 된다.
    - **⌘B / ⌘+클릭** 선언으로: 커서(누른 곳) 아래 이름의 선언으로 간다. 후보가 여럿이면 작은 목록(종류·코드 줄·상대 경로:줄, ↑↓ ↩ esc·클릭).
      순서: 같은 파일 → import 한 것 → 같은 패키지(별표 import) → 같은 폴더 → 가까운 모듈 → 나머지(시험 코드는 같은 칸에서 뒤로).
      `obj.name` 이면 obj 의 타입을 같은 파일에서 어림하고(`userService: UserService`, Java `UserService userService`, `this.userService`),
      그 타입의 패키지(명시 import → 그 패키지, 없으면 같은 패키지·별표 import)를 후보 파일의 `package` 줄과 맞춰 그 클래스의 멤버(companion 포함)와
      그 클래스 파일의 최상위 선언만 남긴다(맞는 것이 없을 때만 이름 전체 후보로). 같은 이름 클래스가 다른 패키지에 있어도 import 한 쪽으로 간다.
      바로 가는 경우: 후보 하나, `obj.` 없는 참조인데 같은 파일에 하나(위쪽 지역 변수가 먼저), import 로 하나로 정해짐. 선언 위에서 누르면 사용 위치.
      ⌘ 를 누른 채 이름 위에 올리면 밑줄·손가락 커서. 간 곳은 가운데로 보이고 이름이 잠깐 밝아진다.
    - **⌥F7**(⌥⌘F7 도, F 키가 미디어 키면 fn 과 함께 · 메뉴 > 이동 > 사용 위치 찾기 · 선언 위 ⌘B) 사용 위치: 프로젝트의 소스 파일에서 이름이 통째로
      나오는 곳(주석·문자열 밖). 가까운 폴더부터 백그라운드에서 찾고 500곳까지. 지금 파일은 저장 안 한 편집 내용으로. 선언 줄은 "선언" 표시.
    - **⌘O** 심볼로(터미널 화면에서도 — 그 화면 폴더의 프로젝트): 클래스·함수·속성 이름을 낙타 혹으로(`UsrSvc` → UserService, `fBI` → findById).
      찾기 칸은 영문 입력으로 바뀐다(한글 자판인 채로 눌러도 바로). 같은 점수면 타입이 먼저.
    - **⌘[ / ⌘]** 뒤로/앞으로(편집기 화면일 때): 위 이동들로 건너뛰기 직전 자리를 파일을 넘어 기억한다(50개). 기록이 없으면 아무것도 안 한다
      (화면 이동으로 넘기지 않음). 터미널 화면에선 그대로 이전/다음 화면, 화면 이동은 ⌘⌥방향키로도.
    - 색인: 처음 이동할 때 그 프로젝트(git 작업 트리 맨 위, 아니면 파일 폴더 — files 도구와 같은 규칙)만 낮은 우선순위로 만든다.
      git 저장소면 `git ls-files -co --exclude-standard`(.gitignore 따름), 아니면 폴더를 걷는다. build·out·target·node_modules·.gradle·.idea·dist·vendor 등은 빼고,
      1MB 넘는 파일·5만 개 넘는 파일은 뺀다. 홈 폴더·/ 같은 넓은 곳은 색인하지 않는다. 이름은 한 번만 들고 선언은 16바이트 줄로(최근 프로젝트 3개만).
      편집기에서 저장한 파일은 바로 다시 읽고, 다른 디스크 변경은 다음 이동 때(10초에 한 번까지) 파일 목록·수정 시각으로 바뀐 것만. 타이머·감시 없음.
      만드는 동안 ⌘B 는 같은 파일 선언으로 바로 가고(안내 "색인 중…"), 다른 파일이면 다 만든 뒤 간다.
    - 선언 찾기: Kotlin·Java(주력) — class·interface·object·enum(항목)·record·annotation class·data class 주 생성자 속성·companion object·
      확장 함수 `fun String.foo()`·제네릭 `fun <T>`·생성자·필드·상수·typealias. TS/JS·Swift·Python·Go·Rust 는 기본 선언.
      정규식·ctags 없이 손으로 쓴 낱말 훑기(주석·문자열 건너뜀, 중괄호로 타입 몸통 추적). 이름 단위라 같은 이름 메서드(오버로드·다른 클래스)는 목록으로 고른다.
  - 닫기(⌘W·탭 닫기·창 닫기·종료)할 때 저장 안 한 내용이 있으면 저장 / 저장 안 함 / 취소를 묻는다. 묻지 않고 저장하는 일은 없다.
  - 모양: 터미널과 같은 JetBrains Mono·크기·바탕(합자는 끔), 줄 번호 여백, 지금 줄 바탕, Darcula 계열 글자 색.
  - 글자 색(Swift·Kotlin/Java·TS/JS·Python·Go·Rust·JSON·YAML·TOML·Markdown·셸·SQL): 정규식 없이 한 번 훑는 스캐너로
    키워드·문자열·주석·숫자·타입·@속성·키 정도만. 보이는 줄만 칠하고(편집하면 보이는 곳만 다시), 블록 주석·여러 줄 문자열 상태는
    약 8KB 간격 기록에서 이어 훑는다. 500KB 넘는 파일은 색 없이.
  - git 변경 표시(IntelliJ 식, HEAD 와 비교): 추가 초록 막대, 바뀜 파랑 막대, 지움 줄 사이 빨간 삼각형. 열 때 `git show HEAD:<경로>` 를
    한 번(백그라운드) 읽고, 편집 뒤 0.3초 모아 줄 단위 Myers diff(앞뒤 같은 줄은 덜어 냄, 다른 곳 2,000 넘으면 한 덩어리로)를 백그라운드에서.
    추적 안 하는 새 파일은 모두 추가, 무시된 파일·저장소 밖은 표시 없음. 2MB·5만 줄 넘으면 표시 없음. 되돌려 저장 내용과 같아지면 ●도 사라진다.
  - 저장: 같은 폴더 임시 파일에 다 쓴 뒤 이름 바꿔 끼움(원래 권한 유지, 심볼릭 링크는 가리키는 파일에). UTF-8(BOM 있으면 유지), 원래 줄 끝(CRLF 등) 유지.
  - 열지 않는 파일: 앞 8KB 에 NUL(바이너리), 5MB 초과, UTF-8 아님 → 읽기 전용 안내(Finder 에서 보기)만.
  - Markdown 미리보기(.md·.markdown·.mdown·.mkd): 여는 건 다른 파일처럼 편집기로. 상태 줄 왼쪽 [편집 | 미리보기] 단추·⇧⌘V·
    보기 > Markdown 미리보기로 그 자리에서 바꾼다. 지금 버퍼(저장 안 한 편집 포함)를 보이고, 디스크에서 바뀌면 다시 그린다(스크롤 유지,
    편집으로 갔다 와도 그 자리). 웹 화면(WKWebView)은 미리보기를 켤 때 만들고 편집으로 돌아가거나 닫으면 버린다.
    변환은 넣어 둔 marked(`Resources/Markdown`, MIT)를 JavaScriptCore 에서 돌리고(실행 중 네트워크 없음), 허용 목록으로 거른 HTML 을
    페이지 스크립트를 끈 웹 화면에 CSP(스크립트·네트워크 막음)와 함께 보인다. 그림은 문서 폴더 안의 것만(원격 그림은 이름표로),
    링크: http·https·mailto 는 기본 앱으로, 로컬 파일은 편집기로(Markdown 이면 미리보기로), #제목은 그 자리 스크롤.
  - 디스크에서 바뀌면(보이는 편집기는 파일 감시, 앱이 앞으로 올 때·탭을 열 때 확인): 고친 게 없으면 조용히 다시 읽고,
    고쳤으면 배너 "디스크에서 바뀌었습니다 · 다시 읽기 / 내 것으로 덮어쓰기". 그 상태의 ⌘S 는 쓰지 않고 배너로 묻는다.
  - 메모리: 편집기 뷰는 보이는 화면만 만든다. 숨은 편집기 중 저장된 것은 글을 놓고(다시 보일 때 디스크에서 읽음), 고친 것은 메모리에 둔다.
    실측(release, 시험 창 약 2056×1262pt, 그림 저장 끔): 편집기 없을 때 194MB → 파일 5개 열고(숨김) 195MB → 그중 하나 보임 195.4MB(나머지는 창 그림 버퍼).
    4.6MB 파일 하나를 열면 TextKit 배치 때문에 약 +140MB, 닫으면 대부분 돌려준다.
  - 한계: 탭을 옮기면 저장된(깨끗한) 문서의 되돌리기 기록은 사라진다(글을 놓으므로). 같은 파일을 두 화면에 나눠 보기는 없다(이미 열린 화면으로 간다).
    글자 색은 줄 단위 근사(정규식 리터럴 등은 모른다). 큰 파일(수 MB)은 열 때 잠깐 멈출 수 있다.
- files 의 git 색(IntelliJ Darcula 계열): 바뀜·이름 바꿈 파랑, 새로 추가(스테이징) 초록, 추적 안 함 적갈색, 무시됨 흐린 올리브, 충돌 빨강,
  색만으로 구분하지 않게 오른쪽에 M·A·R·U·! 글자. 안에 바뀐 것이 있는 폴더는 옅은 파랑(접혀 있어도 보이게).
  `git status --porcelain=v1 -z --untracked-files=normal --ignored=matching` 를 백그라운드에서 한 번 돌린다(`GIT_OPTIONAL_LOCKS=0` — 색인을 고쳐 쓰지 않음).
  다시 돌리는 때: 보이기 시작·루트 바뀜·FSEvents(루트와 작업 트리 git 폴더, 1초 모음, 무시된 폴더 안 변화와 `.git/objects` 는 거름), 최소 1초 간격.
  git 이 없거나(`/usr/bin/git` 설치 창을 띄우지 않게 실제 git 이 있을 때만) 저장소가 아니면 색 없이 트리만.
- 가볍게: 타이머 없음. files 가 숨겨지면 FSEvents 를 멈추고 트리를 놓는다(펼침만 기억). 창이 가려지거나 최소화되면 감시만 멈췄다가 다시 보일 때 새로 읽는다.
  실측(6K 전체 화면 창, release): 창 그림 버퍼(IOSurface 약 100~107MB)는 상태와 무관. 그 밖에 malloc 은 spaces 만 28~30MB,
  같은 도크에서 files 로 바꾸면 23~25MB(SwiftUI 목록이 화면에서 빠짐), spaces+files 둘 다 보이면 32MB, 이 저장소 폴더 9개를 펼친 뒤(95줄) 37~38MB.
  files 를 보이는 채 쉬는 동안 CPU 는 files 없는 때와 차이가 보이지 않았다(git 은 처음 한 번, 이 저장소에서 약 0.1~0.5초).
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
  틈 끌기(`drag`)·스크롤 속도(`scroll <픽셀> <횟수>`)·줄 캐시 검사(`verify-cache`)·보이는 화면 글 출력(`screen`, 대체 화면 여부 포함)·
  한글 조합 시험을 받는다(그림 저장은 메모리를 더 쓰니 측정 땐 끈다).
  도구 창·files 시험 명령: `tool files`(⌘⇧E 와 같음)·`dock files right|left|hidden`·`tool-select spaces`·`uilayout`·`toolmenu files`·
  `filesroot`(루트·브랜치·감시·git 실행 횟수·읽은 줄 수)·`expand <상대 경로>`·`collapse-all`·`open-file <상대 경로>`·`filesmenu <상대 경로>[|<항목>]`·`footprint`.
  편집기 시험 명령: `open-path <절대 경로>[|right|down]`·`editor-type <글>`(`\n` 줄바꿈)·`editor-select <줄>[:<열>]`·`editor-save`·`editor-undo`·
  `editor-state`·`editors`·`editor-answer <save|discard|cancel>`(다음 저장 확인 창 대신 쓸 답)·`editor-banner <reload|overwrite>`·`editor-find`·`editor-snap <png>`.
  이동 시험 명령: `goto [<줄>:<열>]`·`usages [<줄>:<열>]`·`symbol <글>`·`popup`(목록 내용)·`popup-key <up|down|enter|esc>`·
  `cmd-click <줄>:<열>`·`cmd-hover <줄>:<열>`(밑줄 확인)·`nav-back`·`nav-forward`·`nav-state`·`index-state`·`index-build <루트>`(색인 시간·메모리).
  미리보기 시험 명령: `editor-preview [on|off|toggle]`·`editor-preview-state`·`editor-preview-html <파일>`·`editor-preview-snap <png>`·
  `editor-preview-js <식>`(앱 쪽 세계에서 실행)·`editor-preview-raw`(거르지 않은 HTML — CSP·스크립트 끄기만으로 막히는지 확인).
  `CLAUDE_TERM_NO_ACTIVATE=1` 이면 켤 때 앞으로 나오지 않는다(쓰고 있는 다른 앱의 포커스를 뺏지 않게, 시험용).
  이때와 `CLAUDE_TERM_SNAPSHOT` 일 때는 창이 뒤에 있어도 files 감시를 멈추지 않는다.
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
