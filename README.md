# AgentDeck

**Claude Code·Codex 세션을 한눈에 보고, 끊기지 않게 붙잡아 두는 macOS 터미널.**
폴더·작업 트리별 세션 목록과 작업 상태(작업 중·입력 대기·완료), Ghostty 식 탭·분할 터미널, 파일 트리와 가벼운 편집기를 한 창에 담았다.
앱을 꺼도 세션은 계속 돌고, 재부팅해도 탭을 열면 같은 대화로 되살린다.

<!-- 스크린샷 자리: docs/images/main.png 를 넣고 아래 줄의 주석을 푼다
![AgentDeck](docs/images/main.png)
-->

사내 배포용(Apple Silicon 전용, Developer ID 서명 없음 — 설치 스크립트가 격리 속성을 지운다).

## 주요 기능

**세션 유지·복구**
- 셸·claude·codex 는 앱이 아니라 백그라운드 데몬이 붙잡고 있다. 앱을 끄거나 업데이트해도 세션이 그대로 돈다.
- 데몬까지 꺼지면(재부팅·강제 종료) 화면을 "꺼짐"으로 남겨 두고, 탭을 열 때 같은 자리에서 `claude --resume <세션>`(원래 옵션 그대로)·`codex resume <ID>` 로 되살린다.
- 탭·분할 배치, 연 파일, 커서 위치를 기억한다.

**spaces(세션 목록)**
- 폴더(git 저장소)별로 묶고 작업 트리(worktree)를 아래에 펼친다. 셸이 작업 트리로 옮겨 가면 따라간다.
- claude 가 띄운 하위 에이전트를 그 작업 트리 아래에 보인다.
- 세션 이름은 자동(첫 질문으로 짓거나 claude 가 붙인 제목), 직접 바꿀 수도 있다.
- 폴더·작업 트리 접기/펼치기(접힌 줄에 상태 합계), 끌어서 순서 바꾸기.

**상태·알림**
- 화면마다 작업 중·입력 대기(권한 요청·질문)·완료·오류·쉬는 중을 목록·탭·분할 테두리에 점과 글로 보인다.
- 입력 대기·완료·오류가 되면 macOS 알림(누르면 그 화면으로), Dock 배지에 확인이 필요한 화면 수.

**터미널 탭·분할**
- Ghostty 기본 단축키와 모양(JetBrains Mono, D2Coding 한글 — 앱에 들어 있어 따로 설치하지 않아도 된다).
- 좌우·위아래 자유 분할, 탭 끌어서 순서 바꾸기·다른 분할로 합치기·화면을 새 탭으로 꺼내기. 한글 입력 중에도 단축키가 키 위치로 동작한다.

**파일·편집기**
- files 도구: git 상태 색(바뀜·추가·추적 안 함·무시·충돌)이 있는 파일 트리. spaces·files 를 IntelliJ 처럼 왼쪽·오른쪽에 붙이거나 숨긴다.
  파일을 열어도 트리는 보던 자리(펼친 폴더·스크롤·고른 줄)를 지키고 연 파일을 드러내며, 프로젝트를 오가면 프로젝트마다 그 자리로 돌아온다.
- files 에서 열기:
  - 두 번 클릭·Enter = 지금 화면 오른쪽 **미리보기** 화면(분할 제목이 기울어지고 "미리보기"). 다음 파일은 그 자리를 바꿔 쓴다(탭에 하나).
    고치거나 분할 제목을 두 번 누르면(오른쪽 클릭 "고정") 보통 화면이 되고, 다음 파일은 지금 화면 옆에 새 미리보기로 열린다.
  - 이미 열린 파일은 새로 열지 않고 그 화면으로 간다(다른 탭이면 그 탭으로).
  - ⌘두 번 클릭·"새 탭으로 열기" = 새 탭, "오른쪽에 분할로 열기"·"아래로 분할로 열기" = 지금 화면을 나눠서.
  - 여러 파일: ⌘·⇧ 누르며 골라 Enter·두 번 클릭·"열기" → 4개까지는 지금 화면 옆 칸에 위아래로 쌓아(미리보기 자리가 있으면 그 자리에) 보통 화면으로 연다.
    5개 이상이면 "N개 파일을 새 탭에 열까요?"를 물어 새 탭 하나에 격자로 연다(12개까지, 넘으면 앞의 12개). 고른 것 중 폴더는 뺀다.
- 가벼운 편집기(터미널과 같은 탭·분할): 글자 색, HEAD 와 비교한 변경 표시, 찾기·바꾸기, 디스크 변경 감지. IDE 는 아니다(자동 완성·LSP 없음).
- Markdown 미리보기(⇧⌘V, 저장 전 내용도), 이름 단위 코드 이동(선언·사용 위치·심볼, 뒤로/앞으로), 글자 크기 조절.

**새 세션 기본 옵션(설정 ⌘,)**
- + claude·+ codex·폴더 메뉴의 "여기서 … 열기"로 새로 띄울 때 붙일 옵션: claude 는 권한 확인 건너뛰기·권한 모드·모델·추가 인자,
  codex 는 승인·샌드박스 건너뛰기(yolo)·승인 방식·샌드박스·모델·추가 인자. 실제로 실행할 명령을 바로 아래에 보여 준다.
- 이미 실행 중이거나 되살리는 세션은 처음 실행한 옵션을 그대로 쓴다. 권한·승인·샌드박스를 건너뛰는 옵션으로 띄운 세션은 목록 줄에 ⚠(탭 풍선 도움말에도).

**Codex**
- codex 세션도 같은 목록·상태·되살리기에 들어간다. "Codex 연결하기"로 `~/.codex/hooks.json` 에 관찰용 hook 을 넣으면 권한 요청·완료 상태까지 보인다.

## 설치

**준비물**
- Apple Silicon(M1 이상) Mac, macOS 13 이상
- [GitHub CLI](https://cli.github.com) 로그인: `brew install gh && gh auth login`
- 저장소 `jonghyungJeon-private/agent-deck` 접근 권한 — 비공개 저장소라 관리자에게 collaborator 초대를 받고, GitHub 알림·메일에서 수락해야 한다
- Claude Code(그리고 쓰면 Codex CLI)

**설치·업데이트(같은 명령)**

```bash
gh api repos/jonghyungJeon-private/agent-deck/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash
```

최신 릴리스의 `AgentDeck-<버전>.zip` 을 받아 `/Applications/AgentDeck.app`(쓸 수 없으면 `~/Applications`)에 설치하고 연다.
`gh: Not Found (HTTP 404)` 가 나오면 저장소 권한이 없는 것이다(초대 수락 여부와 `gh auth status` 의 계정을 확인).
zip 파일을 직접 받았다면 `bash install.sh AgentDeck-0.2.0.zip`.

## 처음 실행

1. 사이드바 아래 **연결하기** 를 누른다. Claude Code 설정 `~/.claude/settings.json` 에 hook 7개
   (`SessionStart`·`SessionEnd`·`UserPromptSubmit`·`Stop`·`StopFailure`·`Notification`·`PermissionRequest`)를 더한다. 각 항목은 이런 모양이다:

   ```json
   { "type": "command", "timeout": 10,
     "command": "[ -x \"/Applications/AgentDeck.app/Contents/MacOS/AgentDeckDaemon\" ] || exit 0; exec \"/Applications/AgentDeck.app/Contents/MacOS/AgentDeckDaemon\" hook" }
   ```

   - 세션 기록·상태만 앱 데이터 폴더에 적고, 아무것도 출력하지 않으며 claude 의 동작을 바꾸지 않는다(늘 성공으로 끝남).
   - 바꾸기 전에 `settings.json.agentdeck-backup-<시각>` 백업을 남기고, 다른 hook·설정은 그대로 둔다.
   - **앱을 지우거나 옮겨도 안전하다**: 실행 파일이 없으면 아무것도 하지 않고 끝나 어떤 터미널의 claude 에도 오류가 나지 않는다.
   - 새로 시작하는(또는 다시 연) claude 세션부터 적용된다.
2. Codex 를 쓰면 **Codex 연결하기** 를 누른 뒤, Codex 의 `/hooks` 에서 AgentDeckDaemon 훅을 검토·신뢰한다.
3. 위 **+ claude**·**+ codex**·**+ 셸** 이나 ⌘T 로 시작한다.

예전 판(0.3 까지 — 안쪽 이름 ClaudeTerm·ClaudeTermDaemon, 그 전 ClaudeSessions 앱)을 쓰던 PC:
- 설치 스크립트가 `ClaudeTerm.app` 을 `AgentDeck.app` 으로 바꿔 끼운다. 사이드바에 **갱신하기** 가 뜨면 누른다(hook 이 `AgentDeckDaemon` 으로 바뀐다).
- 예전 판의 세션 데몬이 아직 돌고 있으면 새 앱은 그 데몬에 그대로 붙어 열린 세션을 이어 간다. 상태 줄에
  **이전 데몬에서 실행 중 — 재시작(또는 재부팅) 시 새 위치로 옮깁니다** 가 보인다.
  - 그 데몬이 끝나면(재부팅, 화면을 다 닫고 앱을 끔) 앱이 켜져 있으면 바로, 아니면 다음에 켤 때 데이터 폴더 `ClaudeSessions` 를 `AgentDeck` 으로 옮긴다(지우는 것 없음,
    예전 폴더에는 `MIGRATED_TO` 표식만 남김). 탭 배치·이름·spaces 는 그대로이고, 화면은 "꺼짐"으로 남아 탭을 열면 같은 대화로 되살아난다.
  - **지금 옮기기…** 를 누르면 바로 옮긴다. 열린 셸·claude·codex 가 멈추므로(확인 창이 먼저 뜬다) 하던 작업을 정리한 뒤에.
- 묶음 ID 가 바뀌어(`dev.agentdeck.app`) macOS 가 알림 권한을 다시 묻고, 창 위치는 처음 크기로 돌아간다.

연결을 빼려면 메뉴 **AgentDeck > Claude Code 연결 해제…**(Codex 도 같은 자리). 이 앱의 hook 만 빼고 백업을 남긴다.

## 업데이트

- 새 버전이 나오면 왼쪽 아래 상태 줄에 **새 버전 v0.x.y — 업데이트** 가 뜬다(하루 한 번까지, 앱을 켤 때·앞으로 나올 때만 gh 로 확인).
  누르면 업데이트 명령(위 설치 명령과 같음)을 복사하거나 릴리스 페이지를 열 수 있다. 메뉴 **AgentDeck > 업데이트 확인…** 으로 바로 확인한다.
- 업데이트해도 열린 셸·claude 세션은 끊기지 않는다(앱만 바꿔 끼운다).

## 삭제

```bash
gh api repos/jonghyungJeon-private/agent-deck/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash -s -- --uninstall
```

- 무엇을 지울지 보여 주고 묻는다. 앱을 끄고, `~/.claude/settings.json`·`~/.codex/hooks.json` 에서 이 앱의 hook 만 뺀다(백업을 남김).
- 세션 데몬이 돌고 있으면 "열린 세션이 모두 종료된다"고 한 번 더 묻는다. claude 대화 자체는 남아 `claude --resume` 으로 이어 열 수 있다.
- 마지막으로 데이터 폴더(`~/Library/Application Support/AgentDeck`, 남아 있으면 예전 `ClaudeSessions` 도)를 지울지 하나씩 묻는다(기본은 남김).

## 단축키

한글 입력 중에도 키 위치로 동작한다. 모든 항목이 메뉴에도 있다.

| 분류 | 키 | 동작 |
|---|---|---|
| 탭 | ⌘T · ⌥⌘W | 새 탭 · 탭 닫기 |
| | ⇧⌘[ ⇧⌘] (⌃⇧Tab ⌃Tab) | 이전 · 다음 탭 |
| | ⌘1 ~ ⌘8 · ⌘9 | 그 탭 · 마지막 탭 |
| | ⌥⇧⌘← ⌥⇧⌘→ | 지금 탭을 왼쪽 · 오른쪽으로 (끌어서도) |
| 분할 | ⌘D · ⇧⌘D | 오른쪽으로 · 아래로 나누기 |
| | ⌘W | 화면 닫기(셸이 아닌 프로그램이 돌면 묻는다) |
| | ⌘[ ⌘] · ⌥⌘방향키 | 이전 · 다음 화면 · 그쪽 화면으로 |
| | ⇧⌘↩ · ⌃⌘= · ⌃⌘방향키 | 화면 크게 보기 · 크기 같게 · 나눈 선 옮기기 |
| 도구 창 | ⇧⌘E · ⇧⌘S | files · spaces 보이기/고르기/숨기기 |
| 편집기 | ⌘S · ⌘Z ⇧⌘Z | 저장 · 되돌리기/다시 |
| | ⌘F · ⌥⌘F · ⌘G ⇧⌘G | 찾기 · 바꾸기 · 다음/이전 찾기 |
| | ⇧⌘V | Markdown 편집 ↔ 미리보기 |
| 코드 이동 | ⌘B (⌘+클릭) · ⌥F7 · ⌘O | 선언으로 · 사용 위치 · 심볼로 |
| | ⌘[ ⌘] (편집기에서) | 뒤로 · 앞으로 |
| 글자 | ⌘+ · ⌘− · ⌘0 | 크게 · 작게 · 기본 크기(터미널·편집기 글과 함께 탭 줄·분할 제목·spaces·files·상태 줄·이동 목록도 같은 비율로, 0.8~1.6배) |
| 터미널 | ⇧↩ | 줄바꿈(claude 입력에서 여러 줄) |
| 앱 | ⌘, · ⌘H · ⌘Q | 설정(새 세션 기본 옵션) · 가리기 · 종료(세션은 유지) |

## 자주 묻는 질문

**앱을 끄면 세션도 끝나나요?** 아니요. 셸·claude·codex 는 데몬이 붙잡고 있어 앱을 꺼도 계속 돌고, 다시 켜면 그대로 붙습니다.
열린 화면이 하나도 없고 앱도 꺼진 채 60초가 지나면 데몬이 스스로 끝납니다.

**재부팅하면요?** 셸·claude 프로세스는 끝납니다. 대신 탭·분할 배치와 세션 정보가 남아 있어, 탭을 열면 같은 자리에서
`claude --resume`(원래 옵션) 또는 `codex resume` 으로 되살립니다. 한꺼번에 띄우지 않고 여는 탭만 되살립니다.

**데이터는 어디에 있나요?** `~/Library/Application Support/AgentDeck/` — `sessions/`(세션 기록), `codex-sessions/`, `term/`(배치·이름·spaces·설정·로그).
0.3 까지는 `ClaudeSessions/` 였고, 앱이 옮긴다(위 "처음 실행").
Claude·Codex 의 대화 파일은 읽기만 하고 고치지 않습니다.

**앱을 지우면 Claude Code hook 은요?** 0.2 이후 hook 은 실행 파일이 없으면 아무것도 하지 않아 오류가 나지 않습니다.
깔끔히 빼려면 메뉴의 **Claude Code 연결 해제…** 나 삭제 명령(`--uninstall`)을 쓰세요. 0.1 에서 넣은 hook 은 **갱신하기** 를 한 번 눌러야 이 형태로 바뀝니다.

**Intel Mac 에서는요?** 지원하지 않습니다(설치 스크립트가 멈춥니다).

## 개발자용

```bash
swift build && swift test                       # 또는 swift test --filter SessionCoreTests
scripts/build-term-proto.sh                     # dist/AgentDeck.app + dist/AgentDeck-<버전>.zip (VERSION 기본은 스크립트 안)
VERSION=0.3.0 scripts/build-term-proto.sh
```

- 구조·동작 규칙·실측·시험 명령: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). 릴리스 절차·배포 전 점검: [docs/RELEASING.md](docs/RELEASING.md). 변경 기록: [CHANGELOG.md](CHANGELOG.md).
- 이름: 실행 파일 `AgentDeck`·`AgentDeckDaemon`, 묶음 ID `dev.agentdeck.app`, 데이터 `~/Library/Application Support/AgentDeck`, 환경 변수 `AGENTDECK_*`.
  0.3 까지의 이름(`ClaudeTerm`·`ClaudeTermDaemon`·`dev.claude-sessions.term`·`ClaudeSessions`·`CLAUDE_TERM_*`·`CLAUDE_SESSIONS_*`)은
  예전 데몬·hook·셸이 아직 쓰므로 읽기만 이어 간다(자세히는 docs/ARCHITECTURE.md "이름과 예전 판 이어받기").
- 시험은 실제 기록·데몬·설정과 떼어서(예전 이름의 변수도 읽지만 새 이름을 쓴다):
  `AGENTDECK_HOME=<폴더> CLAUDE_CONFIG_DIR=<폴더> CODEX_HOME=<폴더> AGENTDECK_DEBUG=1 AGENTDECK_DEBUG_NAME=<채널> AGENTDECK_NO_ACTIVATE=1 AGENTDECK_NO_NOTIFY=1`.
  데이터 옮기기를 시험할 때는 `AGENTDECK_HOME` 대신 `AGENTDECK_APP_SUPPORT=<가짜 홈>/Library/Application Support`(Foundation 은 HOME 을 따르지 않는다)와
  `HOME=<가짜 홈>` 을 준다. 디버그 명령은 분산 알림 `<채널>`(기본 `dev.agentdeck.debug`)로 보낸다(목록은 docs/ARCHITECTURE.md).
  `open`·AppleScript 로 시험 앱을 다루지 않는다(실행 파일을 직접 띄운다).
- 설치 스크립트 시험: `HOME=<가짜 홈> AGENTDECK_APPS_DIR=<가짜 앱 폴더> AGENTDECK_NO_OPEN=1 bash scripts/install.sh <zip>|--uninstall`(HOME 없이 돌리지 않는다).
- 릴리스 저장소 이름은 `Sources/SessionCore/UpdateCheck.swift`(`repository`)와 `scripts/install.sh`(`REPO`) 두 곳에 있다.
