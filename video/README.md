# AgentDeck 소개 영상

1920×1080 / 30fps / H.264 / 한국어 자막 / 무음. 본편 92초, README용 MP4 티저 14초.
화면 색은 `Sources/AgentDeck/TermAppearance.swift`의 실제 팔레트다.
완성 파일: [92초 본편](out/AgentDeck-intro.mp4), [14초 티저](out/AgentDeck-teaser.mp4),
[대표 프레임 8장](out/frames/), [검토 시트](out/contact-sheet.png).
검증 기록은 [STATUS.md](STATUS.md), coalition 증거는 [verification.json](verification.json)에 있다.

## 다시 렌더링

macOS, Node **18.20.5**, npm, ffmpeg가 필요하다. Remotion **4.0.365**, React **18.3.1**,
TypeScript **5.7.3**을 정확한 버전으로 고정했으며 `package-lock.json`을 함께 사용한다.
한글은 macOS의 Apple SD Gothic Neo, 영문 고정폭은 포함된 JetBrains Mono(OFL)를 사용한다.
앱 없이 `public/`의 선별 PNG로 다시 렌더링할 수 있다.

```bash
cd video
npm ci
npx remotion browser ensure
npm run check
npm run render
npm run teaser
python3 scripts/verify.py
```

실제 렌더 명령:

```bash
npx remotion render src/index.ts AgentDeckIntro out/AgentDeck-intro.mp4 \
  --codec=h264 --crf=18 --pixel-format=yuv420p --concurrency=2 --muted
npx remotion render src/index.ts AgentDeckTeaser out/AgentDeck-teaser.mp4 \
  --codec=h264 --crf=18 --pixel-format=yuv420p --concurrency=2 --muted
```

`out/`, `node_modules/`, `.work/`는 gitignore 대상이다.
검증 스크립트는 8개 대표 프레임과 contact sheet, ffprobe JSON을 `out/`에 만든다.

## 구성

| 구간 | 길이 | 내용 |
| --- | ---: | --- |
| 00:00–00:07 | 7초 | 앱 아이콘, AgentDeck, 한 줄 소개 |
| 00:07–00:14 | 7초 | 흩어진 터미널과 세션 복구의 번거로움 |
| 00:14–00:31 | 17초 | spaces, worktree, 하위 에이전트, 상태, 접힌 합계 |
| 00:31–00:44 | 13초 | 앱 종료 후 데몬 유지 / 재부팅 후 ID로 되살리기 |
| 00:44–00:55 | 11초 | 실제 탭 끌기 전·중·후와 분할 |
| 00:55–01:10 | 15초 | git 색, 미리보기 분할, Markdown, 선언 이동 |
| 01:10–01:22 | 12초 | 알림 동작 설명 / 실행 옵션 설정 |
| 01:22–01:32 | 10초 | README 설치 명령과 0.4.0 |

자막은 46px 이상으로 영상에 직접 포함한다. 전환은 짧은 페이드와 이동, UI 확대·패닝을 사용한다.
설정 창은 CHANGELOG의 **다음 판** 기능이므로 영상에도 ‘개발 중 기능’이라고 표시한다.
알림 카드는 실제 알림을 보내지 않고 만든 **연출 화면**이다.
재부팅 장면은 동작 설명이며 실제 Mac을 재부팅하지 않는다.
재부팅 시 프로세스가 종료되고, 여는 탭에서 같은 대화 ID와 원래 옵션으로 복구된다고 설명한다.

## 캡처의 격리와 단일 인스턴스 보장

캡처 앱은 저장소의 `scripts/build-term-proto.sh`로 빌드한다(`BUNDLE_ID=dev.agentdeck.video.20261019`).
이 셸은 사용자 데몬의 pane 안에 있으므로 실행 파일 직접 실행과 셸에서의 `open` 호출은 금지한다.
`video/.work/launchd/`의 일회용 launchd opener가 `/usr/bin/open -n --env … <W>/dist/AgentDeck.app`을 실행한다.
AppleScript, bundle ID 실행, 실제 디스플레이 캡처·녹화는 사용하지 않는다.
앱 내부 `AGENTDECK_SNAPSHOT`의 2배 PNG만 사용한다.

새 `capture.py run`은 다음을 강제한다.

1. `capture.lock`의 배타 잠금을 얻지 못하면 실행을 거부한다.
2. 재부팅 후 과거 PID를 `ps -p`로 감사하며, 재사용된 다른 프로그램 PID에는 아무 조치도 하지 않는다.
   현재 부팅의 PID 기록과 정확한 worktree 번들 경로의 LaunchServices 항목을 검사해 중복 실행을 거부한다.
3. 실행마다 `.work/runs/run-<시각>-<임의값>/`를 새로 만든다. 데이터·HOME·snapshot 경로와 알림 채널도 실행마다 새롭다.
4. 감독 프로세스는 `dev.agentdeck.videoqa.opener.<counter>` 작업을 bootstrap한다.
   opener만 QA 앱을 한 번 실행하며, 앱 확인 후 opener 작업을 bootout한다. 앱 재시작 명령은 없다.
5. 다른 앱 명령에 앞서 `lsappinfo list`에서 정확한 worktree 번들 경로를 확인한다.
   `ppid=1`이고 `relatedCoalitionPIDs`에 사용자 앱 2522·데몬 2530·그 하위 pane PID가 없어야 한다.
   실패하면 앱을 종료하지 않고 `STATUS.md`를 기록해 즉시 중단한다.
6. 앱이 죽으면 명령을 거부한다. 재시작하거나 다른 앱에 연결하지 않는다.
7. 각 캡처는 명령 이후 새로 생성된 window/terminal/tabbar PNG 한 주기를 확인한다.
   크기는 2400×1520으로 검증하고, 캡처 manifest에 실행 ID·앱 PID·SHA-256을 기록한다.
8. 종료 전 coalition을 다시 확인한 뒤 **검증된 QA 앱 PID만** SIGTERM으로 종료하고 `ps -p`에서 사라질 때까지 기다린다.
   scratch term 경로의 FNV-1a 해시로 데몬 작업명을 계산하고, plist가 `.work/` 안에 있고 Label이 일치함을 확인해 출력한 후
   그 QA 데몬 label만 bootout한다. 사용자 작업 `dev.agentdeck.daemon.c92183e95f9d`에는 접근하지 않는다.
   남은 가짜 pane도 기록된 PID만 종료하고 종료까지 기다린다.

다음 환경 변수는 전부 해당 실행의 디렉터리 안을 가리킨다.
`HOME`, `CFFIXED_USER_HOME`, `ZDOTDIR`, `AGENTDECK_APP_SUPPORT`, `AGENTDECK_HOME`,
`AGENTDECK_TERM_HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `AGENTDECK_CLAUDE_TMP`, `TMPDIR`.
`AGENTDECK_NO_ACTIVATE=1`, `AGENTDECK_NO_NOTIFY=1`, `AGENTDECK_DEBUG=1`을 상속한다.
`claude`, `codex`, `gh`는 PATH 앞의 가짜 프로그램이다. 실제 에이전트·계정·설정에는 접근하지 않는다.
화면 데이터는 가상의 `shop-api`, `shop-web`, `shop-docs`, `feature/coupon`이다.

원래 레이어 캡처에서 터미널 글자가 빠져 `build-capture.sh`가 캡처 빌드에 한해 실제 SwiftTerm
버퍼·문자 속성·글꼴을 투명 오프스크린 비트맵으로 그리도록 보완한다. 내부 창 그림과 같은 좌표로 합성해
편집기·탭·사이드바는 원래 캡처를 보존한다. 별도 bundle ID를 사용하고 창 위치 자동 저장을 비활성화한다.
빌드 종료 trap으로 원래 Swift 파일을 복원하며 제품 소스 변경은 남기지 않는다.

## 새 캡처 만들기

먼저 렌더링과 QA 앱이 종료된 상태에서 저장소 루트에서 실행한다.

```bash
source video/scripts/env.sh
bash video/scripts/build-capture.sh
python3 video/scripts/capture.py run
```

`READY`가 나올 때까지 기다린다. 이 감독 프로세스를 유지한 채 다른 터미널에서:

```bash
python3 video/scripts/capture-scenes.py
# .work/active-run.json의 root 아래 public/ PNG를 검토한다.
python3 video/scripts/capture.py stop
```

감독 프로세스의 `STOPPED`와 실행 폴더의 `cleanup.json`을 확인한다. 검토한 새 PNG만 `video/public/`에 복사한다.
원시 파일과 전체 `lsappinfo` QA 항목 증거는 `.work/`에 남는다. 요약 검증은 `verification.json`에도 보존한다. 기존 raw 폴더를 새 캡처에 재사용하지 않는다.
`capture-scenes.py`는 1200×760pt, 왼쪽 도크 330pt, 글자 16pt를 사용하며 탭 끌기 시작 좌표는 실제 `dragpoints`에서 읽는다.

## 확인 범위

README·CHANGELOG·`docs/ARCHITECTURE.md`와 구현을 확인했다.
가상 상태 기록, 실제 탭 분할, 파일 미리보기, Markdown, 선언 이동, 설정 창을 앱 내부 디버그 명령으로 확인한다.
실제 Claude/Codex 실행, 실제 OS 알림, 실제 재부팅은 수행하지 않는다.
설치 명령은 README 원문을 표시만 하며 실행하지 않는다. 비공개 저장소 접근 권한 조건도 표시한다.
