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
- [ ] `scripts/build-term-proto.sh` → `dist/AgentDeck-x.y.z.zip`. 확인:
  - `lipo -archs dist/AgentDeck.app/Contents/MacOS/ClaudeTerm` 이 `arm64`
  - `plutil -p dist/AgentDeck.app/Contents/Info.plist` 의 `CFBundleShortVersionString`·`CFBundleName`(AgentDeck)·`CFBundleIdentifier`(dev.claude-sessions.term — 바꾸지 않는다)
  - `ls dist/AgentDeck.app/Contents/Resources/Fonts` 에 JetBrains Mono·Nerd Font·D2Coding 과 라이선스
- [ ] 격리 시험으로 hook 연결/해제·새 버전 줄을 본다(README "개발자용", `CLAUDE_TERM_FAKE_LATEST=vx.y.z`). 실제 `~/.claude`·`~/.codex` 로 시험하지 않는다.
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
