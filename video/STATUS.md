# AgentDeck 소개 영상 — 검증 기록

기준 소스: `8852d26`. 2026-10-19 재부팅 후 사용자 승인으로 재개했다.
본편·티저 렌더링과 최종 검증을 완료했다. 아래 캡처·안전 증거는 이번 실행에서 얻은 기록이다.


## 최종 출력과 검사

- `out/AgentDeck-intro.mp4`: **92.000000초**, **8,370,172 bytes**.
- `out/AgentDeck-teaser.mp4`: **14.000000초**, **251,084 bytes**.
- 둘 다 **H.264 / 1920×1080 / 30/1 fps / 비디오 스트림 1개 / 오디오 스트림 0개**.
- ffprobe의 픽셀 형식은 `yuvj420p`(full-range 4:2:0)다.
- `out/frames/`에 본편의 대표 프레임 **8장**을 추출해 검토했다.
- `out/contact-sheet.png`, `out/ffprobe.json`, `out/teaser-ffprobe.json`을 함께 생성했다.
- `npm run check` 및 `python3 scripts/verify.py`가 통과했다.
- 한국어 자막·설치 명령·실제 UI·설정의 개발 중 표기를 포함한 합성 프레임 13장과 최종 추출 프레임 8장을 검토했다.
- 최종 영상과 raw·node_modules·브라우저/렌더 캐시는 gitignore 대상이다. 선별 PNG 합계는 5MB 미만이다.

렌더: `npm run render`, `npm run teaser` (각 `--codec=h264 --crf=18 --pixel-format=yuv420p --concurrency=2 --muted`).
다시 렌더링하는 전체 명령과 8개 장면의 길이는 `README.md`에 있다.

## 이번 실행의 격리 증거

- 실행 ID: `run-20261019-150935-6e2edc`.
- QA bundle ID: `dev.agentdeck.video.20261019`.
- 앱은 직접 실행하지 않았다. `.work/launchd/dev.agentdeck.videoqa.opener.1.plist`의 일회용 launchd 작업이
  `/usr/bin/open -n --env … <이 worktree>/dist/AgentDeck.app`을 실행했다. 앱 시작 후 그 opener만 bootout했다.
- 정확한 worktree 번들 경로를 `lsappinfo list`에서 찾아 앱 PID **12501**을 확인했다.
  첫 명령 전 및 종료 전 모두 **ppid=1, relatedCoalitionPIDs=[], 사용자 PID와 교집합=[]**였다.
  `relatedCoalitionPIDs` 필드가 없는 LS 항목이므로 관련 coalition PID가 보고되지 않은 상태다.
  사용자 앱 2522, 데몬 2530과 그 하위 pane PID를 비교 대상으로 삼았다.
- QA 앱은 이번 실행에서 한 번만 시작했다. 배타 잠금, 현재 부팅의 PID 검사와 정확한 번들 경로 검사로 중복 실행을 거부한다.
- 앱이 띄운 QA 데몬 PID는 **12532**, ppid는 **1**이었다.
- QA 데몬 작업명: **`dev.agentdeck.daemon.323be16390df`**.
  scratch term 경로의 FNV-1a 해시 계산 결과와 plist의 Label이 일치함을 확인했다.
  plist는 `.work/runs/run-20261019-150935-6e2edc/data/term/dev.agentdeck.daemon.plist` 안에 있었다.
- 종료 전 coalition을 다시 검증하고 QA 앱 PID만 SIGTERM으로 종료했다. 그 PID가 사라진 뒤 위 QA 데몬 label만 bootout했다.
  QA 앱·데몬·가짜 pane의 PID가 모두 사라졌고, opener·QA 데몬 launchd 작업도 더 이상 없음을 확인했다.
- 사용자 작업 `dev.agentdeck.daemon.c92183e95f9d`에는 bootstrap/bootout/kickstart를 실행하지 않았다.
  사용자 PID 2522·2530에는 신호를 보내지 않았으며 정리 후에도 두 프로세스가 실행 중임을 읽기 전용으로 확인했다.

영구 요약 증거: `verification.json`.
전체 QA LS 항목·초기/종료 전 검사·환경·cleanup 기록은 gitignored `.work/runs/<실행 ID>/`에 있다.

## 캡처와 내용

새 실행 폴더에서 PNG 9장을 다시 만들었다. 모두 같은 가상 프로젝트·상태 기록·앱 PID를 사용한다.
메인 창은 1200×760pt, PNG는 2400×1520이다. 설정 창은 600×840pt, PNG는 1200×1680이다.
내부 bitmap 스냅샷만 사용했고 실제 디스플레이나 다른 창은 읽지 않았다.
실제 경로·개인 데이터가 없고, git 색·탭 끌기 전/중/후·미리보기·Markdown·선언의 선택 줄이 일관됨을 시각 검토했다.
PNG 합계는 아이콘을 포함해 약 2.55 MB다. `public/captures-manifest.json`에 SHA-256과 크기를 기록했다.
제품 Swift 소스의 임시 캡처 보완은 빌드 후 복원했다. git 변경은 `video/`만 남는다.

13개의 합성 프레임을 검토했다. 자막은 46px 이상, H.264 렌더 동시 작업은 2개다.
Node 18.20.5, Remotion 4.0.365, React 18.3.1을 사용하며 `npm run check`가 통과했다.

## 확인하지 않은 동작

실제 Claude/Codex 실행, 실제 OS 알림 전송, 실제 재부팅·실제 대화 복원, 설치 명령 실행은 하지 않았다.
알림 카드는 ‘연출 화면’, 재부팅 복원은 ‘동작 설명’, 설정 창은 ‘다음 판/개발 중 기능’으로 표시한다.
이 기능들은 README·CHANGELOG·아키텍처와 구현을 근거로 설명한다.

## 이전 실행의 이력

첫 작업에서는 격리 QA 앱 두 개가 겹친 사실을 발견해 사용자 지시대로 중단했다.
이후 macOS coalition 위험이 새로 확인됐으며, 그 이전 직접 실행 드라이버는 폐기했다.
재부팅 후 과거 PID 하나가 다른 프로그램에 재사용돼 있었고 그 PID는 신호 없이 그대로 두었다.
이번 결과는 새 launchd opener 방식의 검증된 한 실행에서만 만든 캡처를 사용한다.
커밋·푸시·릴리스는 하지 않았다.
