# AgentDeck 구조와 자세한 동작

README 는 쓰는 사람용 요약이고, 여기는 만드는 사람용 자세한 설명이다(동작 규칙·실측·한계·시험 명령).

## 구조

```
AgentDeck.app/Contents/MacOS/
  AgentDeck           화면 앱(AppKit + SwiftUI). 목록·탭·분할·도구 창·편집기
  AgentDeckDaemon     세션 데몬(PTY 를 붙잡음) + hook 처리(hook / codex-hook / unhook) + 진단(ctl)
  ClaudeTermDaemon    → AgentDeckDaemon 심볼릭 링크(예전 이름 — 이미 떠 있던 claude 세션의 hook 용, 아래 "이름과 예전 판 이어받기")
```

- 묶음 ID `dev.agentdeck.app`, 데이터 `~/Library/Application Support/AgentDeck`, 환경 변수 `AGENTDECK_*`. 0.3 까지의 안쪽 이름에서 바꿨다(아래).
- 앱 ↔ 데몬: 유닉스 소켓(`term/daemon.sock`)으로 짧은 메시지(`Sources/TermWire`). 데몬은 앱이 **launchd 작업**으로 띄워(아래 "데몬 띄우기")
  앱의 coalition 밖에 있으므로 앱이 끝나도·강제 종료돼도 남는다(setsid 만으로는 부족하다 — 아래).
  앱은 정한 데이터 위치를 `AgentDeckDaemon --root <폴더>` 로 넘긴다(셸 환경에 남지 않게 인자로).
- Claude Code·Codex hook → 데몬 실행 파일이 세션 기록 파일(`sessions/<세션>.json`, `codex-sessions/`)에 적고, 앱은 2초마다 목록을 다시 만들며 읽는다.
- 소스: `Sources/AgentDeck`(앱), `Sources/AgentDeckDaemon`(데몬), `Sources/TermWire`(앱↔데몬 메시지·데이터 위치 `DataLocation`·환경 변수 `AgentDeckEnv`),
  `Sources/TermLayout`(탭·분할·되살리기 정보, 작업 트리 읽기, 도구 창 배치), `Sources/EditorCore`(편집기의 화면 없는 부분: 줄 diff·줄 끝·바이너리 판별·
  안전한 저장·글자 색 훑기·선언 찾기·이름 맞추기·이동 기록), `Sources/SessionCore`(hook 처리·hook 설치/제거·세션 기록·대화 파일 읽기·프로세스 정보·업데이트 확인),
  `Sources/CPTY`(forkpty), `Vendor/SwiftTerm`(고친 터미널 엔진, `PATCHES.md`).
- 데이터(`~/Library/Application Support/AgentDeck/`, `AGENTDECK_HOME` 으로 바꿈): `sessions/`(Claude 세션 기록), `codex-sessions/`,
  `term/`(소켓·로그·`layout.json`·`names.json`·`spaces.json`·`ui.json`·`launch.json`·`codex-bindings.json`·`update-check.json`, `AGENTDECK_TERM_HOME` 으로 바꿈).
- 새 버전 확인: 켤 때·앞으로 나올 때, 마지막 확인(`term/update-check.json`)에서 24시간이 지났을 때만 백그라운드에서
  `gh release view --repo <저장소> --json tagName,url`(저장소는 `UpdateCheck.repository`). gh 가 없거나 로그인·권한이 없거나 오프라인이면 조용히 넘어간다.

## 이름과 예전 판 이어받기

0.3 까지는 표시 이름만 AgentDeck 이고 안쪽은 예전 이름이었다. 지금은 모두 AgentDeck 이고, 예전 이름은 읽기만 이어 간다.

| 무엇 | 지금 | 예전(계속 읽음) |
|---|---|---|
| 실행 파일 | `AgentDeck`·`AgentDeckDaemon` | `ClaudeTerm`·`ClaudeTermDaemon`(번들에 링크로 남김) |
| 묶음 ID | `dev.agentdeck.app` | `dev.claude-sessions.term`(설치 스크립트가 끄기·지우기에 씀) |
| 데이터 | `~/Library/Application Support/AgentDeck` | `…/ClaudeSessions`(옮긴 뒤 `MIGRATED_TO` 표식만) |
| 데이터 위치 변수 | `AGENTDECK_HOME`·`AGENTDECK_TERM_HOME` | `CLAUDE_SESSIONS_HOME`·`CLAUDE_TERM_HOME` |
| 화면 ID(셸 환경) | `AGENTDECK_PANE` | `CLAUDE_SESSIONS_PANE`(예전 데몬이 띄운 셸) |
| 시험 변수 | `AGENTDECK_<이름>` | `CLAUDE_TERM_<이름>` |
| 셸의 `TERM_PROGRAM` | `AgentDeck` | `ClaudeTerm` |
| hook 명령 | `…/AgentDeckDaemon" hook` | `…/ClaudeTermDaemon" hook`(가드 있음·없음), `…/ClaudeSessions" hook` → "갱신하기" 대상, 연결 해제 때 함께 뺌 |
| 디버그 알림 | `dev.agentdeck.debug` | — |
| 설정 백업 | `*.agentdeck-backup-<시각>` | `*.claudeterm-backup-*`(지우지 않음) |

데이터 위치(`TermWire/DataLocation`). 예전 데몬(그 안의 셸·claude)을 끊지 않으려고 이렇게 정한다:

| 새 데몬 | 예전 데몬 | 예전 폴더에 데이터 | 표식 | 앱이 켤 때 | hook·ctl 이 적는 곳 |
|---|---|---|---|---|---|
| 살아 있음 | (무엇이든) | | | 새 위치 | 새 위치 |
| 없음 | 살아 있음 | | | **예전 데몬에 붙음**(legacy, 새 데몬 안 띄움) | 예전 폴더 |
| 없음 | 없음 | 있음 | 없음 | **옮긴 뒤** 새 위치 | 예전 폴더(곧 함께 옮겨짐) |
| 없음 | 없음 | 있음 | 있음 | 새 위치(다시 옮기지 않음) | 새 위치 |
| 없음 | 없음 | 없음 | | 새 위치(처음 설치) | 새 위치 |

- 환경 변수(`AGENTDECK_HOME`, 예전 `CLAUDE_SESSIONS_HOME`)가 있으면 늘 그 위치이고 옮기지 않는다(개발·시험).
- "데몬이 살아 있음" = `term/daemon.pid` 의 프로세스가 이 앱의 데몬 실행 파일(새·예전 이름)이거나 `term/daemon.sock` 에 붙을 수 있음.
  재부팅 뒤 PID 가 다른 프로그램에 다시 쓰여도, 소켓 파일만 남아도 속지 않는다. 잠깐 소켓이 안 받아도 살아 있는 데몬의 폴더를 옮기지 않는다.
- 옮기기: 새 폴더가 없으면 폴더째 이름 바꾸기(같은 볼륨이라 한 번에), 있으면 없는 항목만 옮기고(폴더는 안으로 합침) 겹치는 파일은 예전 폴더에 남긴다.
  지우는 것은 없다. 끝나면 예전 폴더에 `MIGRATED_TO`(새 위치·시각). 결과는 새 `term/daemon.log` 에 한 줄. 실패하면 예전 폴더를 데이터 위치로 삼아
  이 앱의 데몬을 거기서 띄우고(상태 줄에 오류), 다음에 켤 때 다시 시도한다.
- 하나씩 옮기다 일부가 실패하면(권한 등 — 겹침과 다르다) `MIGRATED_TO` 를 남기지 않고 남은 항목 기록을 예전 폴더의 `MIGRATION_PENDING` 과 새 위치의 `term/migration-pending.json` 둘 다에 남긴다
  (예전 폴더가 읽기 전용이어도 다시 시도하게. 둘 다 못 쓰면 기록에 남기고 이번 실행 동안 알림만 보인다).
  새 위치가 기준이 되고(hook·ctl 도 새 위치에 적는다), 실패한 항목마다 `term/daemon.log` 에 한 줄, 상태 줄에
  "데이터 옮기기 일부 실패 — 다음 실행 때 다시 시도합니다"(풍선 도움말에 항목·기록 위치). 다음에 켤 때 예전 데몬이 없으면
  (새 데몬이 돌고 있어도) 남은 항목만 다시 옮기고, 다 옮기면 `MIGRATED_TO` 를 남기고 두 기록을 지운다.
- legacy 동안: 상태 줄에 "이전 데몬에서 실행 중 — 재시작(또는 재부팅) 시 새 위치로 옮깁니다"와 **지금 옮기기…**(앱 메뉴에도).
  새 탭은 예전 데몬에 만들어진다. 예전 데몬이 끝나면(앱이 다시 붙으려다 알게 됨) 그 자리에서 옮기고 새 데몬을 띄운다.
- 지금 옮기기: 확인 창(열린 셸·claude 가 멈춘다는 경고) → 배치를 저장하고 앱의 연결을 먼저 끊음(끄는 동안 오는 목록으로 화면이 배치에서 빠지지 않게)
  → 소켓으로 화면마다 kill(끊김 신호, 3초 뒤 강제) → 화면이 다 끝나면 `daemon.pid` 가 이 앱의 데몬 실행 파일일 때만 SIGTERM(안 끝나면 SIGKILL)
  → 1초 기다려 끝나며 도는 hook 이 예전 폴더에 다 적게 → 옮기기 → 새 데몬. 데몬 ID 가 바뀌었으니 화면은 "꺼짐"으로 남고(되살리기 정보가 있는 것)
  보이는 탭부터 `claude --resume` 으로 되살아난다.
- 메모리에 있는 배치·이름·spaces·Codex 연결은 그대로 이어지고 저장 경로만 바뀐다(옮긴 파일과 같은 내용).
- 번들의 `ClaudeTermDaemon` 링크: Claude Code 는 세션을 시작할 때 hook 설정을 읽어 두므로, 이미 떠 있던 claude 는 갱신하기를 눌러도
  예전 경로(`…/ClaudeTermDaemon hook`)를 계속 부른다. 업데이트로 그 파일이 없어지면 그 세션들의 상태 기록이 끊기므로 링크로 새 데몬에 잇는다.
  예전 데몬이 다 끝난 뒤의 판에서 뺀다.

## Codex CLI

- 사이드바의 **+ codex**(좁은 사이드바에서는 **+ 새 세션 → Codex**)와 폴더·작업 트리의 오른쪽 클릭 메뉴에서 실행한다.
- 실행 중인 대화형 Codex만 화면의 셸 계보로 찾는다. `exec`·`app-server`·node 래퍼는 세션으로 세지 않는다.
- `CODEX_THREAD_ID`와 `AGENTDECK_PANE`(예전 데몬의 셸은 `CLAUDE_SESSIONS_PANE`), 훅 기록, 명시적인 `codex resume <UUID>` 인자로 세션을 연결한다. 폴더가 같다는 이유로 최근 대화를 연결하지 않는다.
  확인된 연결은 Codex PID·시작 시각과 함께 `term/codex-bindings.json`에 저장한다. 연결 전에도 프로그램명 **codex**는 표시된다.
- Codex의 `state_5.sqlite`·`thread_history_1.sqlite`와 기존 `sessions/**/*.jsonl`을 읽기 전용으로 읽어 이름·작업 상태를 표시한다.
  `CODEX_HOME`을 지정한 CLI는 해당 폴더를 읽는다. 이름 변경은 앱 내부 이름만 바꾼다. Codex 대화·설정·DB는 수정하지 않는다.
- 탭·분할 제목, 폴더·작업 트리 묶음, 작업 상태 점, 완료 확인·알림·Dock 배지에도 반영한다.
  Codex 하위 에이전트는 부모 세션과 연결해 표시하고, 작업 폴더가 작업 트리와 일치하면 그 아래에 둔다.
- **Codex 연결하기**는 `~/.codex/hooks.json`에 관찰용 훅을 추가한다(기존 설정 백업·다른 훅 보존).
  Codex의 **`/hooks`에서 새 훅을 검토·신뢰해야** 권한 요청·질문 대기·완료 상태를 정확하게 받을 수 있다.
  훅은 `AgentDeckDaemon codex-hook`으로 기록만 남기며, 승인 결정·모델 문맥은 반환하지 않는다.
  연결 전에 실행한 세션은 도구 실행 등에서 세션 ID가 확인된 뒤 이름·복원 정보가 연결될 수 있다.
- 데몬 재시작·재부팅으로 사라진 Codex 화면은 저장된 정확한 ID로 `codex resume <UUID>`를 실행한다.
  모델·프로필·권한 등의 원래 옵션과 `CODEX_HOME`을 이어받고, 첫 질문·`--last`·`--worktree`는 다시 실행하지 않는다.
  예전 Claude 전용 배치 파일도 그대로 읽는다.

## 터미널 찾기

- ⌘F·⌘G·⇧⌘G는 현재 화면 종류로 나눠 보낸다. Markdown 미리보기와 설정 창에서는 편집기의 숨은 텍스트 뷰로 보내지 않는다.
- 일반 버퍼는 scrollback+화면, Claude 등의 대체 버퍼는 현재 화면만 검색한다. 데몬의 지난 출력 전체 검색은 지원하지 않는다.
- TermLayout의 셀 추출·검색 인덱스·커서가 개수와 강조를 함께 정한다. 실제 셀 열을 기록하므로 출력한 공백·한글·줄바꿈에서도 같은 범위를 쓴다.
- 행 객체와 generation·열 수·다음 줄의 wrap/넓은 글자 여부로 추출 결과를 캐시하고, 바뀌지 않은 논리 줄은 검색 결과까지 재사용한다.
- 검색어 변경은 100ms 모으고 IME 조합 중에는 적용하지 않는다. 출력 직후 강조만 복원하고, 150ms 모은 갱신은 개수·기존 앵커 이후의 일치만 맞춘다. 출력 갱신으로 스크롤하지 않는다.
- 찾기 막대는 overlay라 PTY 행·열을 바꾸지 않는다. Esc는 수정 키 없이 검색 칸에 포커스가 있을 때만 닫는다.

## 데몬 띄우기(launchd 작업)

**setsid 로는 데몬이 살아남지 못한다.** 예전에는 앱이 `posix_spawn` + `POSIX_SPAWN_SETSID` 로 데몬을 띄웠다. setsid 는 세션·프로세스 묶음만 바꾸고
앱의 **coalition** 은 그대로라, 데몬과 그 아래 셸·claude 가 모두 앱의 coalition 에 남는다. 앱(또는 화면 안에서 직접 실행한 AgentDeck 실행 파일)이 끝나면
loginwindow 가 그것을 "남은 앱"으로 보고(`applicationDeath … has related coalition pids [데몬, zsh, claude…]`) Background Task Management(BTM)에
뒤에서 돌아도 되는지 묻는다. BTM 이 허락하면 Dock 에 남은 아이콘으로 두지만, 모르는 앱 정체(새 묶음 ID·새 경로·작업 트리 빌드 등)로 결국
"not allowed to run in the background" 가 되면 `_LSForceQuitApplication … killing coalition pid <데몬>` — 데몬과 모든 화면이 **SIGKILL** 된다.
Dock 의 남은 AgentDeck 아이콘을 "강제 종료"해도 같다(2026-10-19 사용자 세션이 이렇게 두 번 끊김, unified log `category == "quitsupport"` 로 확인).
새로 설치한 동료도 똑같이 겪는다.

그래서 앱은 데몬을 자기 coalition 을 갖는 launchd 작업으로 띄운다(`TermWire/DaemonLaunchAgent`, 앱 `DaemonClient.launchDaemon`):

- 작업 이름 `dev.agentdeck.daemon.<term 폴더 경로의 FNV-1a 64 앞 12자리>`(데몬 하나 = term 폴더 하나라 그 경로로 정한다. 시험 폴더마다 다르다).
- `term/dev.agentdeck.daemon.plist` 를 쓰고 `/bin/launchctl bootstrap gui/<uid> <plist>`(셸 없이). 내용: `ProgramArguments` = [이 앱의 `AgentDeckDaemon`, `--root`, <데이터 위치>],
  `RunAtLoad`, `KeepAlive=false`(쉬다 끝나는 것과 싸우지 않게 — 그래서 `launchctl submit` 은 쓰지 않는다), `AbandonProcessGroup`(데몬이 끝나도 셸을 거두지 않게),
  `ProcessType=Interactive`, 표준 출력·오류 → `term/daemon-stderr.log`, `EnvironmentVariables`(아래).
- 데몬이 끝날 때(쉬다 끝남·SIGTERM) 자기 작업도 내린다(`launchctl bootout`, 끝날 때까지 최대 3초 기다림). 작업이 올라간 채 남으면
  LaunchServices 가 그 작업을 올린 앱에 묶어 둔다(`lsappinfo` 의 `loadedJobs`, loginwindow `has non-ignorable loaded jobs`) —
  그러면 앱이 끝난 뒤에도 Dock 에 남은 아이콘(exited-with-subordinates)으로 붙잡혀 BTM 판단을 받는다. 데몬과 함께 작업을 내리면
  예전처럼 데몬이 끝날 때 남은 아이콘도 사라진다(`applicationExited … has fully exited`). 이 묶임은 올린 쪽을 바꿔도
  (launchctl 의 책임 프로세스 떼기, 한 번짜리 올리기 작업, 실행 파일을 앱 밖으로 복사, 다른 이름 접두어) 없어지지 않았다(2026-10-19 실측).
- 강제로 끝난 데몬(SIGKILL)의 작업은 올라간 채 멈춰 있다. 다음에 띄울 때 `launchctl print` 로 **돌고 있지 않음을 확인한 뒤에만** `bootout` 하고
  새 plist 로 다시 `bootstrap` 한다(앱 경로·환경이 바뀌었을 수 있다). 돌고 있는 작업은 절대 내리지 않는다(내리면 launchd 가 SIGTERM → 화면이 다 끝난다).
  이미 올라가 있어 `bootstrap` 이 실패하면 `kickstart`(`-k` 없이 — 돌고 있으면 그대로)로 시작만 한다.
- 앱은 소켓에 붙지 못할 때만 띄운다. 이미 돌고 있는 데몬(예전 방식으로 뜬 것 포함)에는 그대로 붙고, 띄우는 방식을 바꾸려고 다시 띄우지 않는다.
  예전 방식으로 뜬 데몬은 스스로 끝난 뒤(화면을 다 닫고 60초, 재부팅 등) 다음에 띄울 때부터 launchd 작업이 된다.
- 붙기·띄우기·기다리기는 메인 스레드 밖에서 한다(`TermWire/DaemonConnector` 순서, 앱 `DaemonClient.connect`). 그동안 터미널 자리와 상태 줄에
  "세션 데몬 연결 중…", 붙으면 목록을 받아 화면을 붙인다. launchctl 은 한 번에 최대 3초(넘으면 띄운 그 launchctl 만 SIGKILL 하고 실패로 본다).
  다 실패하면 상태 줄에 빨간 줄과 1·2·4·8·16·30초(최대) 간격으로 다시 시도(2초 새로 고침은 그 전엔 건너뛴다, 새 화면을 열면 바로 다시).
  예전 방식(posix_spawn)으로 띄웠거나 이미 돌던 데몬이 이 폴더의 launchd 작업이 아니면 상태 줄에
  "세션 유지 제한 — 앱을 강제 종료하면 세션이 끝날 수 있음"(launchctl 이 답하지 않아 모르면 표시하지 않는다).
- 올렸는데 3초 안에 소켓이 안 생기면(막 끝나던 데몬의 작업이 아직 내려가는 중이었던 경우 등) launchd 로 한 번 더 띄우고, 그래도 안 되거나
  launchctl 이 실패하면 예전 방식(posix_spawn + setsid)으로 띄우고 `term/daemon.log` 에 남긴다(앱은 계속 쓸 수 있다 — 단 coalition 위험은 그대로).
  시험용 `AGENTDECK_DAEMON_DIRECT=1` 이면 처음부터 예전 방식.
- **환경**: launchd 작업은 앱의 환경을 이어받지 않는다. 예전처럼 화면 셸이 앱 환경을 그대로 받게, 띄울 때 앱 환경을 `EnvironmentVariables` 로 넘긴다
  (PATH·LANG/LC_*·SHELL·HOME·USER·LOGNAME·TMPDIR·SSH_AUTH_SOCK·`AGENTDECK_*` 시험 변수 등 전부). 빼는 것: launchd 가 작업마다 정하는 `XPC_SERVICE_NAME`·`XPC_FLAGS`,
  앱 표시 `__CFBundleIdentifier`, 셸이 정하는 `_`·`PWD`·`OLDPWD`, 앱을 띄운 화면·세션 표시(`AGENTDECK_PANE`·`CLAUDE_SESSIONS_PANE`·`CODEX_THREAD_ID`·`CLAUDECODE`·`CLAUDE_CODE_*` 등).
  화면마다 데몬이 넣는 값(TERM·COLORTERM·TERM_PROGRAM·AGENTDECK_PANE·LANG 채우기)은 예전과 같다. 올린 뒤에는 plist 에서 환경을 지운다
  (launchd 는 올릴 때 읽은 내용을 쓴다 — 토큰 같은 값이 파일에 남지 않게). 남는 plist 는 이름·경로 기록이고 삭제 스크립트가 `Label` 을 읽는다.
- 데몬은 시작할 때 어떻게 떴는지 남긴다(`시작 (launchd 작업 dev.agentdeck.daemon.…)` 또는 `시작 (직접 띄움(posix_spawn), 부모 pid N)`).
  SIGTERM 을 받으면 `SIGTERM 받음, 끝냄 (화면 N개, 연결 M개)` 를 남기고 끝난다 — 기록 없이 사라졌으면 SIGKILL(강제 종료) 이다.
  launchd 작업이면 이어서 `launchd 작업을 내림: <이름>`.
- 재부팅·로그아웃하면 작업은 사라진다(`~/Library/LaunchAgents` 에 두지 않으므로 로그인할 때 저절로 뜨지 않는다 — 예전과 같다).
- 삭제(`install.sh --uninstall`): 데몬을 끄기로 확인받은 뒤(끈 데몬은 스스로 작업을 내린다), 데이터 폴더의 `term/dev.agentdeck.daemon.plist` 에
  적힌 작업이 남아 있으면 `launchctl bootout` 하고 plist 를 지운다. 아직 돌고 있는데 끄기로 한 데몬이 아니면(개발 빌드 등) 그대로 둔다.
- 남은 위험: 앱이 끝난 뒤 데몬이 도는 동안은 여전히 Dock 에 남은 아이콘(올린 작업 때문)이 있고, BTM 이 "허락 안 됨" 이라 하거나 그 아이콘을
  강제 종료하면 loginwindow 가 `_LSForceQuitApplication` 을 부른다. 그때 죽이는 대상은 앱의 coalition·하위 앱이고 데몬은 거기에 없지만,
  올라간 작업을 어떻게 다루는지는 실측하지 못했다(허락 안 됨 경로를 재현하지 못했고, Dock 강제 종료는 사람이 눌러야 한다).
- 확인: `launchctl print gui/$UID/<이름>`(state·pid), 데몬 `ps -o ppid` 가 1. 이름은 `term/dev.agentdeck.daemon.plist` 의 `Label`.

## 터미널 그리기 성능

기본은 CoreText/CoreGraphics 다. 세대 번호가 바뀌어도 셀 내용·폭·색/스타일/밑줄·payload 와 행 표시 상태가
정확히 같으면 기존 CTLine 을 재사용한다. 해시 충돌을 피하려고 셀 snapshot 을 논리 값으로 비교한다.
선택·검색 강조·깜박임·링크는 별도 조건이며 글꼴/색/표시 옵션 변경은 캐시를 비운다.
원래 약 60fps 일회성 coalescing 뒤 마지막 렌더와 내용이 같은 행의 무효화를 생략하고, 바뀐 행 rect 만 요청한다.
캡처가 캐시를 먼저 채워도 창 갱신을 생략하지 않도록 마지막 updateDisplay 의 행 버전과 cache epoch 를 따로 기록한다.
스크롤백·viewport/크기/행 배치 변경·이어진 문단·BiDi·이미지/Kitty 는 보수적인 기존 영역 갱신을 유지한다.
커서·선택·IME·접근성·delegate 알림은 기존 경로를 쓴다. 자세한 조건과 시험은 Vendor/SwiftTerm/PATCHES.md 에 있다.
1차 glyph/좌표 캐시·draw 행 경계·caret clip·minimumDisplayInterval/비포커스 제한 변경은 대형 효과가 작아 모두 철회했다.
기존 drawTerminalContents 본문과 CaretView·TerminalHostController 는 기준 코드 그대로다.

재현기는 `scripts/render-benchmark.py` 다. QA 앱 하나만 별도 bundle ID/데이터/가짜 CLI 와 한 번짜리 launchd opener 로
실행한다. 매 실행 직후 정확한 QA 묶음 경로의 lsappinfo 에서 launchd 실행·ppid 1·relatedCoalitionPIDs 와 coalition
구성원을 확인하고 사용자 데몬/자손이 포함되면 진행하지 않는다. 실제 claude/codex 는 실행하지 않는다.

```bash
/usr/bin/python3 <worktree>/scripts/render-benchmark.py full-frame --control <worktree>/.qa/<시험>/mode --fps 12 --variant full
python3 scripts/render-benchmark.py sample <QA앱PID> <출력.csv> --seconds 30
```

full-frame 은 실제 PTY 크기를 쓰며 한글·Latin·굵은 글씨·상자 선·256색으로 채운 대체 화면을 12fps 로 전송한다.
`full` 은 같은 본문 전체를 다시 보내고 스피너/프레임 번호는 매번, 상태 번호는 2초마다 바꾼다.
`spinner` 는 본문은 처음 한 번만 보내고 이후 두 상태 행만 보낸다. `thirty` 는 전체를 재전송하면서 본문 25행과
두 상태 행(27/89행)을 바꾼다. mode 에 `quit` 을 쓰면 셸로 돌아오며 mode.pid·mode.full.json 에 PID·셀 수·fps·바이트 수를 남긴다.
작은 animate 의 idle 은 Python 이 18Hz 로 도는 정적 TUI 이므로 셸 idle 측정에 쓰지 않는다. burst 는 약 50MiB 출력이다.

측정 때 snapshot off 를 재전송하고 render-state 의 snapshotNext 가 먼 미래인지 확인한다. 전환 뒤 30초 안정화하며
빌드·테스트·캡처·프로파일링은 측정 밖에서 한다. 주 지표는 ps 누적 TIME 차이 / 실제 경과 시간 ×100 이다.
1초 간격 끝점을 포함해 30초는 31개, 60초는 61개 표본을 CSV/JSON 에 남긴다. 한 코어가 100% 이며 ± 는 회차 평균의
표본 표준편차(n−1)다. ps %cpu 는 감쇠 평균이어서 짧은 구간 비교의 주 지표로 쓰지 않는다.
대형 측정은 sample 의 --notifier/--debug-channel/--state-log 로 매초 render-state 를 남기고 all_visible 을 검사한다.

2026-10-21 최종 비교(Apple M3 Pro·18GiB·macOS 27.0.1, release -j 2): 기준은 main 4ff2b18 렌더 코드와 공통 QA 명령,
수정은 content-based row reuse 다. 재개 시 연결 화면이 1920×1080·1배율 하나로 바뀌어 이전 13pt·2배율 표본과 섞지 않고
양쪽 모두 새로 측정했다. 대형은 JetBrains Mono/D2Coding **8pt·321×89칸**, 창 1621×1030pt/터미널 1621×980pt 로 화면 안에
배치했다. window-pin·window-position 0 0·terminal-grid 321 89 를 쓰고 key/focus/visible/activeSpace=true 를 확인했다.
원래 요청의 13pt·6K 화면에서 최종 수정본의 비교 측정은 미검증이다. 이 결과를 그 조건의 수치로 해석하지 않는다.

| 부하 (각 3×30초) | 기준 ΔCPU 초 (1/2/3회) | 수정 ΔCPU 초 (1/2/3회) | 기준 CPU % 평균±SD | 수정 CPU % 평균±SD | 감소 |
|---|---|---|---:|---:|---:|
| 전체 재전송·같은 본문 | 19.24 / 19.24 / 19.25 | 6.73 / 6.66 / 6.72 | 64.10±0.02 | 22.33±0.13 | 65.2% |
| 스피너/상태 두 행만 전송 | 2.59 / 2.63 / 2.68 | 2.45 / 2.59 / 2.54 | 8.77±0.15 | 8.42±0.24 | 4.1% |
| 전체 재전송·약 30% 변경 | 19.06 / 19.09 / 19.06 | 13.54 / 13.54 / 13.50 | 63.53±0.06 | 45.07±0.08 | 29.1% |

같은 본문 전체 재전송은 **65.2% 감소**해 이 조건에서 25% 목표를 넘었다. 약 30% 행 변경도 29.1% 감소했다.
스피너 변형은 4.1% 감소에 그쳐 큰 개선을 확인하지 못했다. 새 내용의 조판/그리기와 ANSI 파싱 비용은 남는다.
대형 전 회차는 31/31 표본에서 visible=true 였고 실제 전송은 약 12fps 였다.
시간 측정 밖의 5초 drawstats 에서 전체 재전송은 기준 평균 41.89ms·전체 그리기 60회·cache hit/miss 0/5340,
수정 평균 0.68ms·전체 그리기 0회·hit/miss 5334/63 이었다. hit 은 무효화 판정과 draw 재사용을 합한 수다.
양쪽 verify-cache 는 89행 모두 일치했다. 이번에는 더 큰 렌더 변경을 추가하지 않았다.

idle 은 13pt·80×40칸, 1200×788pt 창의 실제 zsh 프롬프트다. 보임은 key/focus=true 와 caret opacity 애니메이션,
숨김은 NSApp.hide 뒤 visible=false·caret 애니메이션 없음을 확인했다.

| idle (각 5×60초) | 기준 ΔCPU 초 (1–5회) | 수정 ΔCPU 초 (1–5회) | 기준 CPU % 평균±SD | 수정 CPU % 평균±SD |
|---|---|---|---:|---:|
| 보이는 프롬프트·깜박이는 커서 | 0.54 / 0.54 / 0.51 / 0.52 / 0.55 | 0.53 / 0.55 / 0.56 / 0.52 / 0.53 | 0.89±0.03 | 0.90±0.03 |
| 숨긴 창 | 0.83 / 0.88 / 0.84 / 0.89 / 0.87 | 0.69 / 0.69 / 0.68 / 0.66 / 0.69 | 1.44±0.04 | 1.14±0.02 |

보이는 idle 의 차이 +0.010%p 는 회차 변동폭 안이며 idle 회귀를 확인하지 못했다. 숨김은 0.30%p 낮았다.
예전 0.59→1.72% 는 안정화 5초 뒤 단일 30초 ps 감쇠 평균이어서 idle 회귀 근거로 쓰지 않는다.
원래 coalescing 은 출력 때만 예약하는 일회성이며 새 반복 타이머/display link 를 추가하지 않았다.

다섯 시각 비교는 content-delivery-reference/visual 과 content-delivery/visual 의
01-static, 02-selection, 03-ime, 04-resize, 05-scrollback 각각 *-window.png·*-terminal.png 다.
한글 폭/굵기·상자 선·256색·커서·선택·한글 조합 overlay·크기 변경·스크롤 위치를 눈으로 확인했다.
AppKit bitmap 으로 비교한 10쌍 모두 픽셀 차이 0 이다(content/visual-comparison.txt).
창 캡처는 기존 helper 가 layer 배경색을 빼며 보조 terminal.png 합성은 CoreText 글자가 빠지거나 아래 여백에 중복 흔적을 남길 수 있어,
글자/행/스크롤 시각 판정은 window.png 를 쓴다. 실제 키보드 IME 후보 창·실제 Claude·WindowServer CPU/GPU 메모리는 미측정이다.

Metal 은 이번에 다시 측정하지 않았고 기본은 CoreText 다. 앞선 115×40칸 작은 시험에서는 CPU 시간 7.25%,
Metal 리소스 60,637,184바이트(57.8MiB)로 CoreText 보다 이점이 없었다. IME/caret 소유권 검증이 끝나지 않아
일반 opt-in 설정과 기본값 전환은 보류한다. 셰이더 bundle 복사는 빌드 스크립트에 유지한다.

원자료는 worktree 의 .qa/renderperf 아래 content-delivery-reference 와 content-delivery,
집계는 content/delivery-results.json 이다(git 제외). 최종 비교에서 제외한 이전/중단 자료는 보존한다.
재개한 opener 20/21 의 앱 PID 19164/24601 은 모두 ppid 1·launchd=true·relatedCoalitionPIDs=[] 이며 사용자 데몬/자손과
겹치지 않았다. 사용자 세션이 정리했다고 알린 직전 QA 90635 는 다시 signal 하지 않았다.
각 launch-check.txt 와 launches.json 에 안전 확인/정리를 기록한다.
최종 cleanup-audit.json 에서 정확한 QA 앱 경로가 없고, scratch 에 기록된 opener/daemon plist 42개의 label 이 모두 내려갔음을 확인했다.
기록한 benchmark producer 와 직접 띄운 display assertion 도 종료했다.

## 자세한 동작

- 셸·claude 는 앱이 아니라 `AgentDeckDaemon` 이 붙잡고 있다. 앱을 끄거나 다시 빌드해도 계속 돌고, 앱을 다시 켜면 그대로 붙는다.
  데몬은 화면도 앱 연결도 없이 60초가 지나면 스스로 끝난다. 재부팅하면 셸·claude 는 끝난다.
- 메모리: 앱은 지금 탭에 보이는 화면만 터미널 뷰를 만든다(다른 탭은 데몬이 화면당 최대 2MB 의 지난 출력만 보관).
  그래서 탭이 늘어도 앱 메모리는 거의 그대로다(화면 6개로 나눈 탭도 약 76MB). 실측(M 시리즈, release): 앱 빈 상태 28MB, 화면 보는 중 약 62~65MB(뒤로 보기 2,000줄), 데몬 3~9MB.
  글자가 화면에 찍히는 동안(입력·claude 작업 중)은 macOS 가 그리기용 그래픽 메모리를 약 +130MB 붙였다가, 멈추고 몇 초 뒤 돌려준다.
  창 크기·그리기 방식(Metal 포함)과 무관하고, 빈 창 하나만 띄운 시험 앱이나 iTerm2 도 똑같다(시스템 동작, 새는 것 아님).
- 화면 ↔ 세션 짝짓기: 데몬이 화면의 tty 를 정확히 알고, hook 기록의 tty 와 맞춘다(추측 없음). 셸에는 `TERM_PROGRAM=AgentDeck`, `AGENTDECK_PANE=<화면 ID>` 가 들어간다(예전 이름 `CLAUDE_SESSIONS_PANE` 은 빼서 넘긴다).
- 모양: Ghostty 기본값과 같게 — JetBrains Mono 13pt + Nerd Font 아이콘(`Resources/Fonts`, 앱 안에서만 등록), 배경 #282c34·Tomorrow Night 색, 늘 보이는 스크롤 막대.
  한글은 앱에 넣은 D2Coding 1.3.2(`Resources/Fonts/README.md`, 굵은 글자 포함)로, Ghostty 처럼 소문자 높이를 JetBrains Mono 에 맞춰 그린다.
  Markdown 미리보기(다른 프로세스라 앱에 등록한 글꼴을 못 봄)에는 한글이 있을 때만 같은 파일을 `@font-face` 로 넘긴다.
- 글자 크기(⌘+ ⌘− ⌘0, `ui.json` 의 `fontSize`): 터미널·편집기 글꼴과 함께 앱 테두리도 배율 = 크기 ÷ 13(0.8~1.6, 0.5pt 단위,
  `TermLayout/UIScale`)로 따라간다. 한 곳(`TermAppearance.uiScale`·`scaled(_:)`·`scaledUIFont(_:)`)을 거친다: 탭 줄 높이·글꼴(도구 창 머리 줄·도구 버튼 줄도
  탭 줄 높이를 따라 한 선에 맞음 — 터미널 줄 수가 바뀌면 창 크기를 바꿀 때처럼 데몬에 알린다), 분할 제목 줄, 편집기 상태 줄·편집/미리보기 단추,
  이동 목록(⌘B·⌥F7·⌘O, 열 때마다 새로 만듦), files(줄 높이·들여쓰기·아이콘 — 펼침·고른 줄·맨 위 줄을 지키며 다시 그림), spaces·상태 줄(SwiftUI,
  `UIScaleModel` 이 `\.uiScale` 로 내려 주고 `.uiFont(11)`·`ui(6)` 로 쓴다). 타이머 없이 `fontSizeChanged` 알림으로만 바뀐다.
- Shift+Enter = 줄바꿈(⌥+Enter 와 같은 ESC CR 을 보낸다).
- 되살리기: 화면마다 지금 폴더·claude 세션·claude 실행 옵션(세션 지정 인자 뺀 것, 예: `--dangerously-skip-permissions`)을 배치와 함께 저장한다.
  데몬이 바뀌면(강제 종료·재부팅 뒤 새로 뜸) 사라진 화면을 지우지 않고 "꺼짐"(속 빈 점)으로 남기고, 그 탭을 열 때
  같은 자리·같은 ID 로 셸을 다시 띄워 `claude --resume <세션>` 을 원래 옵션으로 실행한다(대화가 없던 세션·셸은 셸만).
  한꺼번에 다 띄우지 않아 가볍다. 같은 데몬에서 셸·claude 가 스스로 끝난 화면은 Ghostty 처럼 닫힌다.
- Claude Code hook(SessionStart·SessionEnd 와 작업 상태용 hook — 아래 "작업 상태 표시와 알림")은 앱 안의 데몬 실행 파일이 맡는다(`AgentDeckDaemon hook`, AppKit 없이 가볍게 끝남).
  명령은 `[ -x "<경로>" ] || exit 0; exec "<경로>" hook` 형태라 앱을 지우거나 옮겨도 오류 없이 아무것도 하지 않는다
  (0.1 의 가드 없는 형태, 예전 이름 `ClaudeTermDaemon`·`ClaudeSessions` 는 "갱신하기" 대상).
  연결이 안 됐거나 예전 것이면 사이드바 아래에 안내와 "연결하기/갱신하기" 버튼이 뜬다.
  누를 때만 `~/.claude/settings.json` 을 고치고(백업을 남김), 예전 이름 hook 은 같이 뺀다. hook 이 적는 위치는 위 "이름과 예전 판 이어받기".
- 되살릴 때 이어받는 claude 옵션은 허용 목록(권한·모델·effort·add-dir·MCP·허용 도구 등)만. 처음 질문·`--worktree`·세션 지정은 뺀다.
- 새 세션 기본 옵션(설정 창 ⌘,, `term/launch.json`, `TermLayout/LaunchOptions`): + claude·+ codex·폴더 메뉴 "여기서 … 열기"가
  `TermModel.newAgent` 로 `claude <옵션>`·`codex <옵션>` 을 셸에 넣는다. 인자는 화면 짝짓기 때 프로세스 인자에서 다시 읽어
  되살리기 정보(`claudeArgs`·`codexArgs`)에 남으므로, 되살릴 때는 그 세션을 띄운 옵션을 쓰고 지금 기본값은 넣지 않는다(허용 목록에 없는 추가 인자는 빠짐).
  권한 확인 건너뛰기가 켜지면 `--permission-mode` 를, yolo(`--dangerously-bypass-approvals-and-sandbox`)가 켜지면 승인·샌드박스를 넣지 않는다.
  값 목록은 claude 2.1.303·codex-cli 0.162.1 의 `--help` 기준(codex `-a` 는 on-request·never 만 받는다). 파일에 빠진·모르는 칸은 기본값으로 읽는다.
  권한·승인·샌드박스를 건너뛰는 인자(`LaunchDanger`)로 뜬 화면은 spaces 줄에 ⚠, 탭 풍선 도움말에 ⚠ 설명, + 버튼도 기본값이 그러면 ⚠.
- 지난 출력을 다시 그리는 동안 터미널이 내는 응답·클립보드 쓰기는 버린다(예전 질의의 답이 지금 claude 입력으로 새지 않게).
- 지난 출력은 앞에서부터 잘리므로 긴 claude 세션은 맨 앞의 대체 화면 켜기(`ESC[?1049h`)가 사라진다. 그대로 다시 그리면
  claude 화면이 보통 화면에 남고 `/exit` 뒤 "Resume this session with:" 가 그 위에 겹쳐 보였다.
  - 데몬: 버리는 바이트만 모드 추적기(`TermWire/TerminalModeTracker`)에 먹여, 남은 출력이 시작하는 시점의 모드
    (대체 화면, 커서 숨김, DECCKM, bracketed paste, 마우스·포커스, kitty 키보드 스택)를 기억하고, 붙을 때 기본값과 다른 것만
    앞에 붙여 보낸다(동기 출력 2026 은 빼고). 데몬이 새로 떠야 적용된다(지금 돌고 있는 데몬의 세션은 그대로).
  - 앱(예전 데몬에도 통하는 대비책): 지난 출력에서 처음 만나는 대체 화면 켜기·끄기가 끄기면 먼저 켜고 그린다.
    하나도 없으면 "대체 화면 상태 모름"으로 표시해, 대체 화면이 아닌데 끄기가 오면 화면을 지우고 맨 위에서 이어 간다(PATCHES.md).
  - 시험용 스위치: 데몬 `AGENTDECK_NO_MODE_PREFIX=1`(앞 모드 안 붙임 = 예전 데몬 흉내), 앱 `AGENTDECK_NO_ALT_FALLBACK=1`(대비책 끔).
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
  ⌘K 화면 지우기(터미널만: 화면·뒤로 보기를 지우고 Ctrl-L 전송 — 데몬 replay 버퍼는 안 지워져 탭 전환 후 지운 내용이 다시 보일 수 있음. 후속: 데몬에 replay 비우기 프레임 추가) · ⌘P 세션 빠른 전환 · ⌘⇧[ ⌘⇧] 또는 ⌃Tab ⌃⇧Tab 이전/다음 탭 · ⌘1~8 탭, ⌘9 마지막 탭 · ⌥⇧⌘← ⌥⇧⌘→ 지금 탭을 왼쪽/오른쪽으로 한 칸. 새 탭·분할은 지금 화면의 폴더에서 열린다.
- 탭·화면 옮기기(배치만 바뀌어 셸·claude 는 다시 뜨지 않는다, 터미널·편집기 둘 다):
  탭을 끌어 순서를 바꾼다(끄는 탭이 마우스를 따라가고 다른 탭이 비켜 선다, 조금만 움직이고 놓으면 클릭). 순서는 `layout.json` 에 남고 ⌘1~9 도 따른다.
  탭을 탭 줄 밖으로 끌어 지금 탭의 화면 위에 놓으면 가장 가까운 가장자리 쪽 절반이 강조색으로 보이고, 놓으면 그 화면을 나눠 탭째(분할 나무 그대로) 들어간다.
  분할 테두리 제목 줄을 끌면 그 화면만 옮긴다: 다른 화면 위 = 그쪽으로 나눠 넣기, 탭 줄 위 = 그 틈에 새 탭(세로 줄로 보임).
  제목 줄 오른쪽 클릭·셸 메뉴 > 새 탭으로 꺼내기. 비게 된 탭은 닫히고 포커스는 옮긴 화면으로. 탭을 누르면 놓을 때 골라진다(끌어서 지금 탭에 합칠 수 있게).
- 이름은 한 규칙으로 정해 탭·왼쪽 목록·분할 테두리에 똑같이 쓴다(앞의 것이 있으면 그것):
  ① 이 앱에서 직접 바꾼 이름(탭 두 번 클릭, 탭·목록 오른쪽 클릭, 셸 메뉴 > 이름 바꾸기 — 비우면 자동 이름으로)
  ② 사람이 붙인 claude 세션 이름(/rename, `claude -n`). claudec 처럼 `<폴더>@<브랜치>`·`<폴더>-<HHMM>` 로 기계적으로 붙인 이름은 건너뛴다
  ③ claude 가 스스로 붙인 제목(ai-title) ④ 첫 질문으로 지은 제목(Orca 처럼) ⑤ 폴더 이름.
  ④ 는 세션마다 한 번 `claude -p --model sonnet`(설정·hook·MCP·도구·대화 저장 없이, 약 3초)으로 짓고 `term/names.json` 에 둔다.
  짓는 동안은 첫 질문 앞부분을 보여 준다. `AGENTDECK_AUTO_TITLE=0` 이면 부르지 않는다. 실패 이유는 `term/title-errors.log`.
  claude 세션 자체의 이름(`claude --resume` 목록)은 바꾸지 않는다.
- 도구 창(IntelliJ 식): 창 = [왼쪽 도크 | 터미널 | 오른쪽 도크]. 도구는 **spaces**(세션 목록)와 **files**(파일 트리) 둘이고,
  각각 왼쪽·오른쪽·숨김 중 한 곳에 붙는다. 한 도크에 둘이 붙으면 위에 도구 버튼 줄(고른 것은 강조색)이 생기고, 보이는 도구가 없는 도크는 접힌다.
  도구 버튼·머리 줄 오른쪽 클릭 = 왼쪽으로/오른쪽으로 옮기기·숨기기. 보기 메뉴에도 있다.
  ⌘⇧E files, ⌘⇧S spaces: 숨김이면 마지막 쪽에 보이고 고름 → 보이지만 안 골랐으면 고름 → 고른 상태면 숨김(한글 입력 중에도 키 위치로).
  ⌘⇧E 로 열면 트리에 포커스가 가고, Esc 는 터미널로 돌아간다.
  기본값은 spaces·files 둘 다 왼쪽, spaces 를 고른 채로(IntelliJ 의 Project 창 자리, 터미널 폭은 그대로). 배치·고른 도구·도크 폭은 `term/ui.json`
  (없거나 예전·망가진 파일이면 기본값).
- files: 포커스 화면의 작업 트리 맨 위(작업 트리가 아니면 화면 폴더)를 보인다. 머리 줄에 폴더 이름·브랜치·바뀐 파일 수, 오른쪽에 모두 접기.
  다른 프로젝트 화면으로 포커스가 옮겨 가면 루트가 바뀌고, 펼친 폴더·보던 자리(맨 위 줄·고른 줄)는 루트별로 메모리에만 기억해
  돌아오면 그대로 보인다(루트 12개·루트당 400개까지, `TermLayout/ExpansionMemory`). 루트가 같으면 트리를 다시 만들지 않는다.
  NSOutlineView 로 그리고, 폴더는 펼칠 때 백그라운드에서 읽는다(`.git`·`.DS_Store` 뺌, 폴더 먼저 → 대소문자 무시 이름순, 점 파일은 흐리게).
  두 번 클릭·Enter = 편집기로 열기(아래). 오른쪽 클릭: (파일이면) 오른쪽에 나눠 열기·아래에 나눠 열기, Finder 에서 보기·경로 복사·상대 경로 복사·여기서 셸 열기(새 탭).
  편집기 화면이 포커스면: 지금 루트 안의 파일이면 루트를 그대로 두고(상위 폴더를 둘러보다 하위 저장소 파일을 열어도 보던 트리를 잃지 않게),
  밖이면 터미널 화면과 같은 규칙(그 파일 폴더의 작업 트리 맨 위, `TermLayout/FilesRoot`). 도구를 숨겼다 다시 보여도 숨기기 전 루트를 기준으로 한다.
  그 파일을 트리에 드러낸다(위 폴더를 차례로 펼치고 고른 뒤 보이게 스크롤, 다른 폴더는 접지 않음, 여러 줄을 골라 둔 가운데면 고른 것을 그대로).
  여러 줄 고르기(⌘·⇧). 열기 규칙(미리보기·고정·여러 개)은 README "파일·편집기", 배치 계산은 `TermLayout/FileOpening`.
- 편집기: files 에서 두 번 클릭·Enter 하면 지금 화면 오른쪽 미리보기 화면에 연다(탭에 하나, 다음 파일이 그 자리를 바꿔 쓴다 —
  바꿔 쓴 화면은 배치에서 빼고 문서를 닫는다). 미리보기는 `editors` 의 `preview: true` 로 저장되고, 고치면(●) 또는 분할 제목 두 번 누르기·
  "고정"으로 지운다. ⌘두 번 클릭·"새 탭으로 열기"·코드 이동·Markdown 링크는 예전처럼 지금 탭 바로 뒤 새 탭(고정). 이미 열린 파일이면 그 화면으로 간다(나눠 열기도 같음).
  - 터미널과 같은 탭·분할에 들어간다(배치 잎 ID `editor:<UUID>`). 데몬과 상관없어 데몬 목록 맞추기에서 지워지지 않고 셸로 되살리지도 않으며,
    spaces 목록에 나오지 않는다. 연 파일·커서 위치는 `term/layout.json`(`editors`)에 저장돼 앱을 다시 켜면 다시 열린다.
  - 탭·분할 테두리 제목 = 파일 이름, 저장 안 했으면 뒤에 ●. 아래 상태 줄에 줄:열·UTF-8·줄 끝(LF/CRLF)·언어.
  - 단축키: ⌘S 저장(파일 메뉴, 키 위치로 받아 한글 입력 중에도 — ⌘⇧S 는 그대로 spaces), ⌘F 찾기 막대·⌥⌘F 바꾸기·⌘G/⌘⇧G 다음/이전,
    ⌘Z/⌘⇧Z 되돌리기(문서마다 따로, 탭을 옮겨도 이어짐), ⌘X 잘라내기. 되돌리기·잘라내기는 편집기에서만 켜지고, 찾기는 지금 화면 종류로 보낸다.
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
    처음 열기·다시 읽기는 읽기 전후 지문(수정 시각·크기·inode)이 같을 때만 받아들인다. 최대 3회에도 계속 바뀌면 충돌로 남기고 기존 글을 지킨다
    (처음 열기는 읽기 실패 안내). 저장 지문은 경로를 다시 읽지 않고 직접 쓴 파일의 fd 에서 얻는다.
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
  폴더·작업 트리 줄을 누르면(▸/▾) 접고 편다. 접힌 줄 둘째 줄에는 안(작업 트리·세션·하위 에이전트까지)의 상태 합계 — 같은 상태 점 + 수,
  입력 대기·오류는 붉은 테두리로 따로, `↳N` 일하는 하위 에이전트, 세션 수. 머리 줄 버튼·오른쪽 클릭으로 모두 접기/펼치기.
  폴더 머리 줄·세션 줄을 끌어 순서를 바꾼다(세션은 같은 작업 트리 안에서만, 다른 칸에 놓으면 무시). 이 순서는 목록에서만 쓰고
  탭 순서·⌘1~9 는 바뀌지 않는다. 새 세션은 칸 맨 뒤에 붙는다. 접힘·순서는 `term/spaces.json` 에 저장한다(묶음은 경로, 세션은 화면 ID).
- 스크롤: 바뀌지 않은 줄은 지난번 그린 결과를 다시 써서 한 번 그리기가 약 1/3 로 줄었다(PATCHES.md).
- 터미널 엔진은 한글 폭·입력 표시를 고친 SwiftTerm 사본(`Vendor/SwiftTerm`, 고친 내용은 `PATCHES.md`).
- 데이터 위치: `~/Library/Application Support/AgentDeck/term/`(소켓·로그). `AGENTDECK_TERM_HOME` 으로 바꿀 수 있다.
- 진단: `dist/AgentDeck.app/Contents/MacOS/AgentDeckDaemon ctl list | new <cwd> [명령] | send <id> <글> | dump <id> | kill <id>`
  (ctl 도 위 규칙대로 데몬을 고른다 — 예전 데몬이 살아 있으면 그것에 붙는다. 시험 땐 `AGENTDECK_HOME` 을 준다)
- 시험 환경 변수는 모두 `AGENTDECK_*`(예전 이름 `CLAUDE_TERM_*` 도 읽는다). 데이터 옮기기 시험은 `HOME=<가짜 홈>` 과
  `AGENTDECK_APP_SUPPORT=<가짜 홈>/Library/Application Support`(Foundation 의 홈 폴더는 HOME 을 따르지 않는다)를 주고 `AGENTDECK_HOME` 은 주지 않는다.
  예전 데몬을 흉내 내려면 main 의 `ClaudeTermDaemon` 을 `git archive` 로 꺼내 scratch 에서 빌드하고,
  **반드시** `CLAUDE_TERM_HOME`·`CLAUDE_SESSIONS_HOME` 을 가짜 예전 폴더로 주어 띄운다(없으면 실제 폴더를 쓴다).
  시험 프로세스는 띄울 때 기록한 PID 로만 끈다(`pkill`·이름으로 찾아 끄기 금지 — 실제 데몬과 실행 파일 이름이 같다).
- **시험 앱은 반드시 LaunchServices 로 띄운다**: 한 번짜리 launchd opener 작업에서 `open -n --env AGENTDECK_HOME=… --env AGENTDECK_APP_SUPPORT=… --env HOME=<가짜 홈> --env AGENTDECK_NO_ACTIVATE=1 … <경로>/AgentDeck.app`
  을 실행한다(또는 AgentDeck 화면 밖의 셸에서 실행). `ps -o ppid` 가 1 이고, `lsappinfo` 의 `relatedCoalitionPIDs` 에 사용자 데몬이 없는지 확인한다.
  AgentDeck 화면 안의 셸에서 `Contents/MacOS/AgentDeck` 를 직접 실행하면 그 앱이 사용자 데몬의 coalition 에 들어가,
  그 앱이 끝날 때 loginwindow 가 사용자 데몬과 모든 화면을 강제 종료할 수 있다. 같은 이유로 Dock 에 남은 AgentDeck 아이콘(멈춘·끝난 시험 앱)을
  **강제 종료하지 않는다**. 시험 데몬의 launchd 작업은 시험 폴더로 계산한 이름만 `bootout` 한다(다른 `dev.agentdeck.daemon.*` 는 건드리지 않는다).
- 시험용: `AGENTDECK_SNAPSHOT=<폴더>` 면 1초마다 창 그림(window.png)과 터미널 그림(terminal.png, 실제 배경색)을 남기고,
  `AGENTDECK_DEBUG=1` 이면 보낼 알림(`notify <상태> · <이름> key=…`)·Dock 배지 변화(`dock-badge N`)를 표준 출력에 찍고(`AGENTDECK_NO_NOTIFY=1` 과 함께 쓴다), 분산 알림으로 화면 고르기·메뉴 동작(`action split-right` 등)·입력·단축키(`chord cmd+shift+d`)·
  틈 끌기(`drag`)·마우스 단계별(`mouse <down|drag|up|right> <x> <y>`)·오른쪽 클릭 메뉴 항목 실행(`menu-pick <x> <y> <항목>`)·
  탭·분할 나무(`tabs`)·끌기 좌표(`dragpoints`)·스크롤 속도(`scroll <픽셀> <횟수>`)·줄 캐시 검사(`verify-cache`)·보이는 화면 글 출력(`screen`, 대체 화면 여부 포함)·
  한글 조합 시험을 받는다(그림 저장은 메모리를 더 쓰니 측정 땐 끈다).
  도구 창·files 시험 명령: `tool files`(⌘⇧E 와 같음)·`dock files right|left|hidden`·`tool-select spaces`·`uilayout`·`toolmenu files`·
  `filesroot`(루트·브랜치·감시·git 실행 횟수·읽은 줄 수·고른 줄·맨 위 줄·줄 높이)·`expand <상대 경로>`·`collapse-all`·`open-file <상대 경로>`(두 번 클릭과 같음)·
  `filesmenu <상대 경로>[|<항목>]`·`files-select a|b|c`(여러 줄 고르기)·`files-enter`·`files-scroll <상대 경로>`(맨 위로)·`editor-pin`(미리보기 고정)·
  `font-size <pt>`(⌘+ ⌘− 와 같은 길, 배율 출력)·`footprint`. `tabs` 는 편집기를 파일 이름으로, 미리보기는 뒤에 `~` 를 붙여 보인다.
  spaces 시험 명령: `spaces`(보이는 줄·접힌 줄 합계·저장 상태)·`spaces-toggle g:<묶음 경로>|w:<작업 트리 경로>`·`spaces-collapse-all`·`spaces-expand-all`·
  `spaces-move-group <경로>|<대상 경로>`·`spaces-move-session <화면 ID>|<대상 화면 ID>`(ID 는 앞 4글자로도)·`spaces-drag <group|session> <ID>|<대상>`(끄는 모습만 그림)·`spaces-drag-end`.
  `AGENTDECK_DEBUG_NAME=<이름>` 이면 그 이름의 알림만 받는다(기본 `dev.agentdeck.debug`, 시험 앱을 여럿 띄울 때 서로의 명령을 받지 않게).
  편집기 시험 명령: `open-path <절대 경로>[|right|down]`·`editor-type <글>`(`\n` 줄바꿈)·`editor-select <줄>[:<열>]`·`editor-save`·`editor-undo`·
  `editor-state`·`editors`·`editor-answer <save|discard|cancel>`(다음 저장 확인 창 대신 쓸 답)·`editor-banner <reload|overwrite>`·`editor-find`·`editor-snap <png>`.
  세션 이동 시험: `action next-attention`·`switcher <이름·폴더>`·`popup`·`popup-key <up|down|enter|esc>`. `chord cmd+j|cmd+p`는 실제 단축키 경로(⌘K 는 화면 지우기).
  터미널 찾기 시험: `terminal-find <글>`·`terminal-find-state`(개수·선택 문자열·칸·스크롤)·`terminal-find-case on|off`·`terminal-find-close`. `terminal-click`은 터미널 가운데에 실제 마우스 이벤트를 넣고, `pane-find-menu`는 찾기 메뉴의 켜짐을 출력한다.
  창 포커스 시험은 `settings key`·`main-key`, 메뉴 실행 경로는 `pane-find-menu-action pane-find`를 쓴다.
  이동 시험 명령: `goto [<줄>:<열>]`·`usages [<줄>:<열>]`·`symbol <글>`·`popup`(목록 내용)·`popup-key <up|down|enter|esc>`·
  `cmd-click <줄>:<열>`·`cmd-hover <줄>:<열>`(밑줄 확인)·`nav-back`·`nav-forward`·`nav-state`·`index-state`·`index-build <루트>`(색인 시간·메모리).
  미리보기 시험 명령: `editor-preview [on|off|toggle]`·`editor-preview-state`·`editor-preview-html <파일>`·`editor-preview-snap <png>`·
  `editor-preview-js <식>`(앱 쪽 세계에서 실행)·`editor-preview-raw`(거르지 않은 HTML — CSP·스크립트 끄기만으로 막히는지 확인).
  종료 시험 명령: `quit`(⌘Q 와 같은 길 — 데몬·화면이 앱과 따로 남는지 볼 때).
  배포 시험 명령: `alert-answer <번호…>`(다음 확인 창들에서 누를 버튼, 0 = 첫 버튼 — 디버그 중엔 확인 창을 띄우지 않고 내용을 찍는다)·
  `update-state`·`update-open`·`hooks-state`·`settings`(설정 창, 창 번호)·`settings-snap <png>`·`launch-options [<JSON>]`(기본 옵션 보기·바꾸기)·
  `launch <claude|codex> <폴더>`(+ 버튼과 같은 길 — 시험 땐 셸 PATH 맨 앞에 인자만 찍는 가짜 claude·codex 를 둔다)·`rows`(인자·⚠ 포함)·`appmenu`(앱 메뉴 항목·켜짐)·`fonts`(실제로 잡힌 글꼴 파일)·
  `location`(데이터 위치·모드 standard/legacy/custom·연결·화면 수·꺼진 화면 수; 옮기기는 `alert-answer 0` 뒤 `action relocate-data`). `AGENTDECK_FAKE_LATEST=v0.3.0` 이면 gh 대신 그 태그를 최신 릴리스로 본다.
  `CLAUDE_CONFIG_DIR=<폴더>`·`CODEX_HOME=<폴더>` 로 hook 을 넣고 빼는 설정 파일을 시험 폴더로 돌린다(실제 `~/.claude`·`~/.codex` 를 건드리지 않게).
  `AGENTDECK_NO_ACTIVATE=1` 이면 켤 때 앞으로 나오지 않는다(쓰고 있는 다른 앱의 포커스를 뺏지 않게, 시험용).
  이때와 `AGENTDECK_SNAPSHOT` 일 때는 창이 뒤에 있어도 files 감시를 멈추지 않는다.
  실제 창은 `screencapture -l <창 번호>` 로 찍을 수 있다(층 그림은 SwiftUI·글자가 빠지는 일이 있다).

## 작업 상태 표시와 알림

claude 화면마다 지금 무엇을 하는지를 왼쪽 목록(점 + "입력 대기 · 권한 요청" 같은 글), 묶음 점(안의 가장 급한 상태),
탭 제목 앞 점(탭 안 화면 중 가장 급한 상태), 분할 테두리 제목 앞("입력 대기 · <이름>")에 보인다. 색만으로 구분하지 않게 글·모양도 다르다.

| 상태 | 색·모양 | 언제 (Claude Code hook) |
|---|---|---|
| 작업 중 | 노랑 점 | `UserPromptSubmit`(질문을 보냄) |
| 입력 대기 | 빨강 테두리 점, 안 보는 탭은 붉은 바탕 + 아래 줄 | `PermissionRequest`(권한 요청), `Notification` 의 `permission_prompt`·`elicitation_dialog`·`elicitation_url_dialog`·`agent_needs_input` |
| 완료 | 청록 점 | `Stop`(응답을 마침). 그 화면을 보면(앱이 앞에 있을 때) "쉬는 중"으로 바뀐다 |
| 오케스트레이션 중 | 보라 점선 고리 + 가운데 점, "에이전트 N · 백그라운드 M" | `Stop` 의 `background_tasks` 에 아직 도는 일이 있음(아래). 알림·Dock 배지 없음 |
| 오류 | 빨강 점 | `StopFailure`(API 오류 등, 오류 종류를 함께 보임) |
| 쉬는 중 | 초록 속 빈 점 | 완료를 확인했거나 `Notification` 의 `idle_prompt`(입력 없이 약 60초) |

- hook 은 세션 기록 파일(`sessions/<세션>.json`)에 `state`·`stateAt`·`stateMessage`·`pane`·`stateSeq`(상태를 적을 때마다 오르는 번호 — 같은 초 안의 변화도 구분해 알림이 빠지지 않게. 날짜 형식은 예전 빌드와 같다)를 적고, 앱은 2초마다 목록을 다시 만들며 읽는다.
  화면 짝짓기는 hook 이 적은 화면 ID(`pane`)가 먼저다.
- 알림: 입력 대기·완료·오류로 바뀌면 macOS 알림을 보낸다(누르면 그 화면으로). 지금 보고 있는 화면, 앱을 켠 직후 이미 그 상태였던 화면은 알리지 않는다.
  Dock 아이콘 배지에 확인이 필요한 화면 수가 뜬다. `AGENTDECK_NO_NOTIFY=1` 이면 알림을 보내지 않는다(시험용). 묶음 ID 가 바뀌어(0.4) 알림 권한은 다시 묻는다.
- 오케스트레이션 중(메인은 응답을 마쳤는데 맡긴 백그라운드 일이 도는 동안). 실측 Claude Code 2.1.303:
  - **hook**: `Stop` 입력에 `background_tasks`(그때 도는 일 — 상태 running·pending 만, 항목 `id`·`type`(`subagent`·`shell`·`monitor`·`workflow`·
    `teammate`·`cloud session`·`MCP task`·`dream`…)·`status`·`description`)가 온다(바이너리의 Stop 입력 만들기에서 `taskRegistry` 를 직렬화하는 것 확인,
    공식 문서 hooks "Stop input"). hook 이 이 목록을 기록(`background`)에 남긴다. `dream`·`auto-mode scan`·`memory import` 는 내부 정리라 뺀다.
    에이전트 = subagent·teammate·workflow·cloud session, 백그라운드 = 셸·모니터·MCP 작업(모르는 종류 포함). 필드가 없는 예전 판은 예전 그대로(완료).
  - **끝남 확인(파일)**: 앱이 2초 목록 갱신 때, Stop 목록이 남은(완료·쉬는 중·입력 대기) 세션만 일마다 stat·작은 읽기 한두 번(새 타이머 없음).
    - 하위 에이전트: `~/.claude/projects/<폴더>/<세션>/subagents/agent-<id>.meta.json` 의 `"finished":true`(끝날 때 meta 를 고쳐 쓴다.
      SendMessage 로 다시 이어 시키면 finished 가 빠진 meta 로 다시 쓰는 것을 확인). meta 에 없으면(10/16 이전 판) 기록 끝에서 마지막
      `"type":"assistant"` 줄이 `"stop_reason":"end_turn"` 이고 그 뒤에 user 줄이 없으면 끝(실제 기록 20개 모두 meta 와 일치, 도는 에이전트는 tool_use).
    - 셸: `/private/tmp/claude-<uid>/<폴더>/<세션>/tasks/<id>.output`(에이전트는 그 기록으로 가는 링크, 셸은 일반 파일) 끝 줄이
      `[exited with code N]`·`[killed]` 면 끝(실측 — 끝난 것은 모두 표시가 있고, 표시 없는 파일은 `sleep` 이 실제로 열고 있었다).
      출력 파일이 없어졌으면(폴더는 있음) 끝, 폴더를 못 찾거나(`CLAUDE_CODE_TMPDIR` 를 바꾼 경우) 파일이 없는 종류(워크플로 등)는 hook 을 믿는다.
      시험용으로 `AGENTDECK_CLAUDE_TMP` 로 바꾼다.
  - **상태 규칙**(`WorkStateRules.effective`): 완료·쉬는 중 + 도는 일 있음 → 오케스트레이션 중(확인한 완료여도). 다 끝난 직후 60초(`reportGrace`)도
    오케스트레이션 중 — 백그라운드 에이전트가 결과를 보고하면 Claude Code 가 메인 턴을 스스로 시작하고 이때도 `UserPromptSubmit` 가 온다
    (문서: "A background subagent reporting back") → 작업 중 → 남은 일 없는 `Stop` → 완료(알림 한 번). 60초 안에 hook 이 안 오면
    원래 완료로 돌아가 그때 알린다(같은 상태 번호라 한 번만). 하위 에이전트의 권한 요청은 지금처럼 입력 대기(알림)이고, 허락해 그 에이전트 기록이
    늘면(메인 대화는 그대로) 오케스트레이션 중으로 돌아간다.
  - `SubagentStart`·`SubagentStop` hook 도 있지만(입력에 `agent_id`·`agent_type`·`agent_transcript_path`, SubagentStop 도 `background_tasks`)
    넣지 않았다: 백그라운드 일이 끝나면 위 보고 턴의 `UserPromptSubmit`→`Stop` 이 새 목록을 주므로 더 얻는 것이 없고, 넣으면 모든 사용자에게
    "갱신하기" 안내가 다시 뜬다. hook 을 놓쳐도 파일 확인과 60초 대비책이 받친다.
  - 하위 에이전트 줄의 "작업 중"도 같은 끝 표시로 정한다(예전: 최근 1분 안에 기록이 늘었는지 — 긴 명령을 기다리면 끝난 것처럼 보였다).
    끝 표시가 없어도 12분 넘게 기록이 그대로면 멈춘 것으로 본다.
  - Codex: 부모 턴이 끝났는데(완료·쉬는 중) 하위 에이전트(`thread_spawn_edges` 가 닫히지 않았고 그 턴이 진행 중)가 있으면 오케스트레이션 중
    (하위 훑기 10초 주기 결과). `CodexChildRules.activity` 는 작업 중인 자식을 `stateAt` 이 오래됐다는 이유로 제외하지 않는다.
    끝난·닫힌·쉬는 자식은 상태 시각에서 15분 뒤 제외한다. 방치된 기록은 rollout 수정 시각(이미 stat 한 값)과 상태 시각이 모두 24시간 넘게 그대로면 제외한다.
    SQLite 에서 턴을 읽었다면 `thread_history_1.sqlite`·WAL 수정 시각도 함께 본다(rollout 을 더 쓰지 않는 새 CLI 대응).
    공용 DB 에 다른 세션이 쓰면 제외가 늦어질 수 있고, 파일 시각을 모르면 작업 중인 자식을 유지한다. Codex 의 백그라운드 셸은 알아낼 방법이 없어 보지 않는다.
- **기존 사용자는 사이드바 아래 "갱신하기"를 한 번 눌러야 한다.** 예전 연결(SessionStart·SessionEnd 만)으로는 상태 hook 이 없어
  claude 화면이 상태 없이 claude 색 점으로만 보인다. 갱신은 그 뒤 새로 시작하는(또는 다시 연) claude 세션부터 적용된다.
- 알려진 한계:
  - Esc 로 중단하면 `Stop` 이 오지 않아 "작업 중"으로 남는다. 약 60초 뒤 `idle_prompt` 가 와서 "쉬는 중"으로 바로잡힌다.
  - 권한 요청 `Notification` 은 늦게 올 수 있어 `PermissionRequest` 로 바로 "입력 대기"로 바꾼다. 허락한 뒤에는 따로 오는 hook 이 없어,
    "입력 대기" 시각보다 2초 넘게 뒤에 대화 파일이 늘면 다시 일하는 것으로 보고 "작업 중"으로 바꾼다(추정).
  - "완료 → 쉬는 중"은 앱이 앞에 있고 그 화면을 고르고 있을 때만 바뀐다.
  - 끝나지 않는 백그라운드 셸(개발 서버·`tail -f`·모니터)을 띄운 세션은 그것이 도는 동안 계속 오케스트레이션 중이고 완료로 알리지 않는다
    (Claude Code 도 "백그라운드 일이 깨워 줄 때를 기다리는 중"으로 본다).

아직 없는 것: 글꼴·색 설정.
