# SwiftTerm 사본 (AgentDeck 용)

원본: https://github.com/migueldeicaza/SwiftTerm v1.20.0 (5d14406, MIT — LICENSE)
`Sources/SwiftTerm` 만 가져왔다(iOS·문서·예제·테스트·빌드 정보 플러그인 제외, `SwiftTermBuildInfo.swift` 는 고정 파일).

고친 곳은 코드에 `AgentDeck patch` 로 표시했다.

1. 넓은 글자 크기 (`Apple/AppleTerminalView.swift` `glyphSlotFit`, `fallbackWideScale`, `scaledFont`)
   - 한글은 대체 글꼴(설치돼 있으면 D2Coding, 없으면 Apple SD Gothic Neo)로 그려진다. Ghostty 처럼
     한글(또는 한자)이 있는 대체 글꼴은 소문자 높이(x-height)를 주 글꼴과 같게 키우거나 줄인다(D2Coding 은 약 1.05배).
     두 칸 가운데 놓고 기준선은 그대로 둔다. 키운·줄인 글꼴은 캐시해 프레임마다 만들지 않는다.
   - (두 칸을 꽉 채우게 키우면 Ghostty 보다 훨씬 크고, 대문자 높이의 1.1배로 맞추면 Ghostty 보다 작았다.
     Ghostty 화면과 같은 글자를 찍어 잰 비율로 확인했다.)
2. 한글 입력 중 글자 표시 (`Mac/MacTerminalView.swift` `updateMarkedTextOverlay`, `MarkedTextGridView`, `markedTextCursorMoved`, `firstRect`)
   - 원본은 조합 중 글자를 줄 전체 폭의 NSTextView 로 덮어 입력할 때마다 줄이 깜빡였고, 글자 폭·위치가
     확정된 글자와 달라 커서 위치가 애매했다. 음절마다 상자를 없앴다가 새로 만들었다.
   - 조합 중 글자를 터미널 칸에 맞춰(두 칸 글자는 1번과 같은 방식으로 키워서) 그리고 밑줄을 긋는다.
     뒤에 블록 커서를 그려 확정 뒤 커서가 갈 자리를 보여 준다. 덮는 칸만 칠하고, 상자는 다시 쓴다.
   - 조합하는 동안은 터미널 커서를 숨긴다(claude 처럼 커서를 보이게 두는 앱에서 커서가 두 개 보였다).
   - 위치는 커서 칸 기준이고 앱이 커서를 옮기면 따라간다(claude 는 커서를 숨긴 채 입력 위치에 둔다).
     입력기 후보 창 위치(`firstRect`)도 같은 기준.
3. 256색이 틀어지는 문제 (`Apple/AppleTerminalView.swift` `mapColor`, 굵은 글꼴 선택)
   - 원본은 `useBrightColors = false`(Ghostty 의 bold-is-bright = false 와 같은 설정)일 때 7보다 큰
     모든 색 번호에서 8을 뺐다. 그래서 256색까지 밀려 claude 상태줄의 117(하늘)이 109(회청), 147(연보라)이
     139(자주)로 보였다. 번호를 그대로 쓰고, 굵은 글꼴로 바꾸지도 않는다.

4. 입력기 진단 기록 (`Mac/MacTerminalView.swift` `TerminalView.imeTrace`, `traceIME`)
   - 키 입력·조합·확정 호출과 그때 커서 칸을 앱이 넘겨준 함수로 보낸다(앱이 `term/ime-trace.log` 에 남김). 시제품 진단용.

원본을 올릴 때는 위 표시가 있는 곳을 새 버전에 다시 적용한다.

## 굵은 글씨의 대체 글꼴도 굵게 (Mac/MacTerminalView.swift `FontSet`)

굵은·기울인 글꼴을 만들 때 cascadeList(이어서 찾을 글꼴)에도 같은 굵기·기울기를 준다.
원래는 굵은 글씨 속 한글이 대체 글꼴의 보통 굵기로 그려졌다(Ghostty 는 D2Coding Bold 로 그린다).

## 스크롤 성능 (Apple/AppleTerminalView.swift `cachedLineInfo`, `drawBoxDrawings`, Apple/BoxDrawingRenderer.swift)

스크롤은 줄 내용이 아니라 보이는 위치만 바꾸는데, 원본은 그릴 때마다 모든 줄의 글자 묶음(NSAttributedString)과
글자 모양(CTLine)을 새로 만들었다. 줄 객체의 세대 번호(`BufferLine.generation`·`recycleGeneration`)와 열 수·선택 영역·
깜박임·링크 밑줄이 같으면 지난번 결과를 다시 쓴다. 오른쪽→왼쪽 글자·그림이 있는 줄은 담지 않는다.
캐시는 화면 줄 수의 두 배 남짓만 두고(가볍게), 색·글꼴이 바뀌면 비운다.
상자 선(─ │ 등)은 칸마다 NSColor → CGColor 변환을 하던 것을 기존 CGColor 캐시로 바꿨다.
측정(321×89칸, 한글·색·상자 선 섞인 출력): 한 번 그리기 15.7ms → 4.4ms.
`TerminalView.drawTrace`(그리기 시간), `verifyLineCache()`(캐시와 새로 만든 결과 비교)는 진단용이다.
`AGENTDECK_NO_LINE_CACHE=1`(예전 이름 `CLAUDE_TERM_NO_LINE_CACHE`)이면 캐시를 끈다(비교 측정용).

## 대체 화면 상태를 모를 때의 끄기 (Terminal.swift `altScreenStateUnknown`, DECRST 47/1047/1049) — AgentDeck patch

데몬은 화면당 약 2MB 의 지난 출력만 보관해서, 긴 claude 세션은 맨 앞의 `ESC[?1049h`(대체 화면 켜기)가 잘린다.
그 출력을 먹이면 claude 화면이 보통 화면에 그려지고, `/exit` 의 `ESC[?1049l` 은 대체 화면이 아니라 아무 일도 하지 않아
마지막 화면 위에 "Resume this session with:" 가 겹쳐 남았다.

- `Terminal.altScreenStateUnknown`(공개, 기본 false): 앱이 "대체 화면 켜기·끄기가 하나도 없는 지난 출력"을 먹일 때 켠다.
- 47/1047/1049 켜기·끄기가 오면 풀린다.
- 켜진 채 대체 화면이 **아닐 때** 끄기가 오면 켜기를 놓친 것으로 본다: 보이는 화면을 지우고(ED 2) 커서를 맨 위로 옮긴 뒤
  이어 간다(1049 의 저장된 커서는 놓친 켜기의 것이 아니므로 되돌리지 않는다).
- 꺼져 있으면 원래 동작과 같다. 시험: `Tests/SwiftTermPatchTests`.
