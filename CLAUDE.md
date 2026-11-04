# AgentDeck — 작업 규칙

## 릴리스 (절차 전체: docs/RELEASING.md)

- abx 는 앱에 넣어서 배포한다(`Contents/Helpers/abx`, 넣은 버전은 `Contents/Resources/abx/VERSION`).
  앱의 업데이트 확인은 agent-deck 릴리스만 보므로 abx 만 바뀌어도 **AgentDeck 을 새로 릴리스해야** 동료에게 간다.
- 릴리스할 때마다 abx 를 확인한다:
  1. 지난 릴리스에 넣은 abx 커밋: 설치된 앱의 `Contents/Resources/abx/VERSION` 첫 줄(`abx: <커밋>`).
  2. `git -C ../agent-browser log --oneline <그 커밋>..origin/main -- packages/abx` — 나오는 커밋이 이번 릴리스에 들어간다.
  3. 빌드는 `../agent-browser` 의 **지금 상태 그대로** 넣는다: 빌드 전에 그 폴더가 `origin/main` 과 같고 커밋 안 된 변경이 없는지 본다.
     빌드한 앱의 `Contents/Resources/abx/VERSION` 에 `-dirty` 가 붙어 있으면 릴리스하지 않는다.
  4. abx 가 바뀌었으면 CHANGELOG 에 `- abx: <바뀐 점> (abx <커밋>)` 줄을 넣는다.
- 반대로 abx 를 `agent-browser` main 에 올렸는데 아직 릴리스하지 않았으면, 작업을 마칠 때 "AgentDeck 릴리스가 필요하다"고 알린다.
