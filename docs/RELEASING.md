# 릴리스 절차 (관리자용)

릴리스 저장소: `jonghyungJeon-private/agent-deck`(비공개). 이름을 바꾸면 `Sources/SessionCore/UpdateCheck.swift` 의 `repository`,
`scripts/install.sh` 의 `REPO`, README 의 명령 세 곳을 같이 바꾼다.

## 처음 한 번 (저장소 공개 전 점검)

- [ ] **커밋 작성자 메일**: 지금 기록의 작성자는 회사 메일이다(`git log --format='%ae' | sort -u`). 개인 계정 저장소에 그대로 올려도 되는지 정한다.
      바꾸려면 올리기 전에 `git filter-repo --mailmap` 으로 고치거나 새 기록으로 올리고, `git config user.email` 을 GitHub noreply 주소로 둔다.
- [ ] 비밀·개인 정보 훑기: `git ls-files | xargs grep -nIE 'gh[pousr]_|github_pat_|sk-|AKIA|BEGIN .*PRIVATE|/Users/'`(Vendor 의 upstream 디버그 경로는 무시).
- [ ] `.gitignore` 에 `.build/`·`dist/`·`.swiftpm/` 이 있는지(빌드 결과·zip 은 저장소가 아니라 릴리스에만).
- [ ] 저장소 만들기: `gh repo create jonghyungJeon-private/agent-deck --private --source . --push`(gh 계정을 jonghyungJeon-private 로 바꾼 뒤).
- [ ] 동료를 collaborator(Read)로 초대: `gh api -X PUT repos/jonghyungJeon-private/agent-deck/collaborators/<깃허브 아이디> -f permission=pull`.
      동료는 메일·알림에서 초대를 수락해야 한다.

## 매 릴리스

- [ ] `CHANGELOG.md` 에 버전·날짜·바뀐 점, `scripts/build-term-proto.sh` 의 `VERSION` 기본값을 올린다(또는 `VERSION=x.y.z` 로 빌드).
- [ ] `swift build && swift test`(최소 `swift test --filter SessionCoreTests`) 통과.
- [ ] 브라우저: agent-browser 저장소(abx)가 원하는 커밋인지 확인한다(빌드가 `ABX_SRC` 에서 abx 를 만들어 넣는다, 없으면 빌드 실패).
      에이전트 전용 브라우저 고정 판(`Sources/BrowserCore/BrowserInstaller.swift` 의 `BrowserRelease.pinned`)을 그때의 Chrome for Testing
      안정판으로 올린다 — 스스로 업데이트하지 않으므로 보안 수정은 이것으로만 들어간다. 판·주소를 바꾸고 받은 zip 의 `shasum -a 256` 을 넣는다
      (https://googlechromelabs.github.io/chrome-for-testing/ 의 Stable, mac-arm64). 새 판으로 screencast·입력을 한 번 확인한다.
- [ ] `scripts/build-term-proto.sh` → `dist/AgentDeck-x.y.z.zip`. 확인:
  - `lipo -archs` 로 `dist/AgentDeck.app/Contents/MacOS/AgentDeck`·`AgentDeckDaemon` 둘 다 `arm64`(`ClaudeTermDaemon` 은 `AgentDeckDaemon` 링크)
  - `plutil -p dist/AgentDeck.app/Contents/Info.plist` 의 `CFBundleShortVersionString`·`CFBundleName`(AgentDeck)·`CFBundleExecutable`(AgentDeck)·
    `CFBundleIdentifier`(dev.agentdeck.app — 다시 바꾸면 알림 권한·창 위치가 또 초기화된다)
  - `ls dist/AgentDeck.app/Contents/Resources/Fonts` 에 JetBrains Mono·Nerd Font·D2Coding 과 라이선스
  - `dist/AgentDeck.app/Contents/Helpers/abx`·`agent-browser`(arm64), `Contents/Resources/abx/VERSION` 이 의도한 abx 판인지(`-dirty` 가 아닌지)
  - `codesign --verify --deep --strict dist/AgentDeck.app`
- [ ] 격리 시험으로 hook 연결/해제·새 버전 줄을 본다(README "개발자용", `AGENTDECK_FAKE_LATEST=vx.y.z`). 실제 `~/.claude`·`~/.codex` 로 시험하지 않는다.
- [ ] 데이터 위치를 건드렸으면 가짜 홈에서 처음 설치·예전 폴더 옮기기·예전 데몬에 붙기·지금 옮기기를 본다(docs/ARCHITECTURE.md "이름과 예전 판 이어받기").
- [ ] 태그와 릴리스(zip 이름은 `AgentDeck-*.zip` 이어야 설치 스크립트가 찾는다):
  ```bash
  git tag vX.Y.Z && git push origin vX.Y.Z
  gh release create vX.Y.Z dist/AgentDeck-X.Y.Z.zip --repo jonghyungJeon-private/agent-deck --title "AgentDeck vX.Y.Z" --notes-file <(sed -n '/^## X.Y.Z/,/^## /p' CHANGELOG.md)
  ```
  태그 이름은 `v` + 앱 버전(앱이 `CFBundleShortVersionString` 과 숫자로 비교한다). 초안·pre-release 는 `gh release view` 의 최신으로 잡히지 않는다.
- [ ] 다른 계정(collaborator)으로 설치 한 줄을 실행해 본다:
  ```bash
  gh api repos/jonghyungJeon-private/agent-deck/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash
  ```
  이전 버전이 깔린 PC 에서는 상태 줄에 새 버전 줄이 뜨는지(하루 한 번 확인이라 메뉴 **업데이트 확인…** 으로 바로).
- [ ] `scripts/install.sh` 를 바꿨다면 기본 브랜치에 먼저 올린다(한 줄 명령은 기본 브랜치의 스크립트를 받는다).
