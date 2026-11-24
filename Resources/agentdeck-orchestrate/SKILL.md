---
name: agentdeck-orchestrate
description: AgentDeck 의 칸(터미널)을 다루는 도구 — `agentdeck` 명령으로 다른 칸에 claude·codex 를 띄우고(모델·effort 지정), 지시를 보내고, 끝나기를 기다려 답을 받는다. 사람이 지켜보며 끼어들 수 있는 칸에 검토·조사·구현을 맡길 때 쓴다. AGENTDECK_PANE_ID 가 있을 때(AgentDeck 의 칸 안)만. 일을 쪼개고 리뷰·합치는 절차를 정한 다른 스킬(예: orchestrate)이 있으면 절차는 그 스킬을 따르고 이 스킬은 칸 다루는 법으로만 쓴다.
---

# agentdeck — 다른 칸의 에이전트에게 일 시키기

AgentDeck 의 칸(터미널) 하나에 에이전트(claude·codex) 하나가 산다. `agentdeck` 로 다른 칸에 지시를 보내고, 끝나길 기다리고, 답을 받는다.
`AGENTDECK_PANE_ID` 환경 변수가 없으면 AgentDeck 밖이다 — 이 스킬을 쓰지 않는다.

## 다른 스킬과의 관계

이 스킬은 **도구**(칸 다루는 법)다. 일을 어떻게 쪼개고, 누가 리뷰하고, 어떻게 합칠지 정한 스킬(예: orchestrate·token-budget)이 있으면
그 절차와 모델 배정이 우선이고, AgentDeck 칸은 그 절차가 고르는 **실행자 하나**다. 그런 스킬이 없으면 아래 규칙만으로 쓴다.

칸을 쓸 때 / 쓰지 않을 때:
- 쓴다: 사람이 화면을 보며 끼어들 일, 권한 승인이 잦은 긴 작업, 끝난 뒤에도 그 세션을 이어 쓸 일.
- 쓰지 않는다: 잠깐의 조회·요약·짧은 리뷰 — 안 보이는 서브에이전트(Agent 도구)가 더 싸고 화면도 어지럽히지 않는다.

## 모델·effort

```bash
agentdeck new --claude --model sonnet --effort high --name 구현A "…"
agentdeck new --codex --model gpt-5.5 --effort medium --name 조사
```

- 안 주면 AgentDeck 설정의 새 세션 기본 옵션 그대로다. 주면 그 칸에만 덧씌운다(기본 옵션의 추가 인자에 같은 것이 있어도 이 값이 이긴다).
- effort: claude 는 low·medium·high·xhigh·max, codex 는 minimal·low·medium·high·xhigh.
- 일의 무게에 맞춘다: 정해진 명세의 구현·기계적인 일은 가벼운 모델·낮은 effort, 설계·보안 판단·리뷰는 무거운 모델. 모델 배정 규칙을 정한 스킬이 있으면 그것을 따른다.

## 한 건 맡기기: ask

```bash
agentdeck new --claude --name 리뷰어          # 새 칸 + 그 칸의 ID 출력 (같은 탭 오른쪽에 붙음, 폴더는 내 칸의 폴더)
agentdeck ask <칸> "src/foo.ts 를 리뷰하고 문제만 요약해" --timeout 10m
```

`ask` 는 지시를 보내고, 작업이 끝날 때까지 기다리고, 그 칸 에이전트의 **이번 턴 마지막 답**을 표준 출력으로 낸다. 종료 코드:
0 끝남 · 2 입력 대기(권한 요청·질문 — 사람이 답해야 함) · 3 오류 · 124 시간 초과 · 1 그 밖의 실패.
작업 중인 칸에는 `ask` 가 거절한다(지난 턴의 끝을 답으로 착각하지 않게) — `agentdeck wait <칸>` 으로 끝난 뒤 다시.

- 지시가 길거나 여러 줄이면 파일로: `agentdeck ask <칸> --file brief.md` (글을 인자로 줄 때 따옴표·줄바꿈이 깨질 일이 없다).
- 칸은 ID 앞부분(8자)·이름(정확히)·`.`(내 칸)로 부른다. 모호하면 후보가 나온다.
- 상태는 `agentdeck list`(* = 내 칸) / `agentdeck status <칸>`: working · waiting · done · idle · error · dormant.
- 막혔는지 보려면 `agentdeck read <칸> --lines 40`.
- `send`: 입력 대기(waiting — 권한 요청·질문) 칸에는 **보내지 않는다**(종료 코드 2, 이유 출력). Enter 가 사람 대신 "Yes" 를 고르기 때문이다.
  `--force` 는 그 칸이 정말 글을 받을 상태일 때만(대신 허락하려고 쓰지 않는다). claude·codex 칸에는 한 줄 글도 붙여넣기로 보내므로 `!`·`/` 로 시작하는 글이 모드·명령이 되지 않는다.

## 병렬로 시키기

```bash
a=$(agentdeck new --claude --name 작업A "A 를 구현해. 끝나면 변경 파일 목록으로 답해")
b=$(agentdeck new --claude --name 작업B "B 를 구현해. 끝나면 변경 파일 목록으로 답해")
agentdeck wait $a $b --any --timeout 20m     # 먼저 끝난 칸이 나오면 돌아옴(--json 이면 어느 칸인지 기계가 읽을 수 있음)
agentdeck ask $a "방금 한 일을 3줄로 요약해"   # 끝난 칸의 결과
agentdeck wait $b                             # 남은 칸을 마저
agentdeck close $a; agentdeck close $b        # 다 쓴 칸은 닫는다
```

`new` 의 마지막 인자(처음 지시)는 에이전트가 **자기 기록을 남긴 것을 확인한 뒤에만** 보낸다(claude 는 상태 hook 의 SessionStart, codex 는 세션 기록).
폴더 신뢰 확인 같은 창을 지나기 전에는 보내지 않는다 — 확인하지 못하거나 hook 이 없으면 보내지 않고 "처음 지시를 보내지 못함: … agentdeck read 로 확인" 을 내며 종료 코드 2 로 끝난다(칸은 남아 있음):
`read` 로 화면을 보고 사람에게 알리거나, 뜬 뒤 `send` 로 보낸다. 같은 칸 오른쪽에 `new --right --of <칸>` 을 거듭하면 그 줄 아래로 쌓인다(`--down` 은 아래 줄 오른쪽으로).
`wait` 는 일을 **시작한 것을 본 뒤** 끝나길 기다리므로
지시 직후의 쉬는 상태를 끝으로 착각하지 않고, 사용자가 안 본 완료(done)도 끝으로 센다.
`wait` 가 2(입력 대기)로 돌아오면 그 칸이 권한 요청·질문에 막힌 것이다 — `read` 로 내용을 보고 사람에게 알린다(대신 허락하지 않는다).

## 규칙

- 칸을 나눌 때는 **서로 다른 파일**을 맡긴다(같은 폴더에서 같이 고치면 서로 덮어쓴다). 겹치면 칸마다 git worktree 를 쓰게 한다(`new --cwd <worktree>`).
- **커밋·push 는 지시에 있을 때만** 시킨다. 맡긴 칸이 낸 결과는 직접 확인한 뒤 쓴다(끝났다는 말을 그대로 믿지 않는다).
- 다 쓴 칸은 `close`(작업 중·입력 대기면 `--force` 없이는 안 닫힌다). 남이 띄운 칸은 닫지 않는다.
- `new` 의 기본 폴더는 `--of` 칸의 폴더, 없으면 내 칸의 폴더, 그것도 없으면 지금 폴더다. 다른 곳이면 `--cwd`.
- 예전 세션 데몬(앱 업데이트 뒤에도 살아 있음)이 만든 칸에는 `agentdeck` 명령이 없다 — `new` 가 그 사실을 stderr 로 알린다(앱을 끄고 데몬을 새로 띄워야 함).
