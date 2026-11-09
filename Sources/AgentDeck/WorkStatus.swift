import AppKit
import SwiftUI
import SessionCore
import TermLayout

/// claude 화면의 작업 상태(hook 기록에서). 색만으로 구분하지 않도록 글자도 함께 보인다.
enum WorkStatus: Equatable {
    /// claude 가 아니다
    case none
    /// claude 인데 상태 hook 이 아직 없다(연결 갱신 전)
    case unknown
    case codexUnknown
    case working
    /// 권한·질문 등 사람의 입력을 기다린다
    case waiting(String?)
    /// 응답을 마쳤고 아직 안 봤다
    case done
    /// 메인은 응답을 마쳤지만 맡긴 백그라운드 일(에이전트·셸)이 아직 돈다. 끝나야 "완료"로 알린다.
    case orchestrating(agents: Int, shells: Int)
    case idle
    case error(String?)

    init(state: String?, message: String?, background: WorkStateRules.Background? = nil) {
        switch state {
        case "working": self = .working
        case "orchestrating": self = .orchestrating(agents: background?.agents ?? 0, shells: background?.shells ?? 0)
        case "waiting": self = .waiting(message)
        case "done": self = .done
        case "idle": self = .idle
        case "error": self = .error(message)
        default: self = .unknown
        }
    }

    var label: String? {
        switch self {
        case .none, .unknown, .codexUnknown: return nil
        case .working: return "작업 중"
        case .waiting: return "입력 대기"
        case .done: return "완료"
        case .orchestrating: return "오케스트레이션 중"
        case .idle: return "쉬는 중"
        case .error: return "오류"
        }
    }

    var detail: String? {
        switch self {
        case .waiting(let message), .error(let message): return message
        case .orchestrating(let agents, let shells):
            let parts = (agents > 0 ? ["에이전트 \(agents)"] : []) + (shells > 0 ? ["백그라운드 \(shells)"] : [])
            return parts.isEmpty ? "결과 받는 중" : parts.joined(separator: " · ")
        default: return nil
        }
    }

    /// 상태 색(B2 역할): 입력 대기·오류 = 빨강(내 조작 필요), 완료 = 세이지 초록, 작업 중·오케스트레이션 = 주 글자색(숨 쉬는 점), 쉼·없음 = 중립.
    /// 오케스트레이션(메인은 응답을 마쳤지만 백그라운드 일이 도는 중)도 일하는 중이다 — 회색 점선 고리는 쉬는 중의 빈 고리처럼 읽혔다.
    /// 종류 색(주황·청록)은 상태에 쓰지 않는다 — 연결 전 claude·codex 는 "상태 없음"이다.
    var color: NSColor {
        switch self {
        case .none, .unknown, .codexUnknown: return TermAppearance.statusNone
        case .working: return TermAppearance.statusWorking
        case .waiting, .error: return TermAppearance.statusAttention
        case .done: return TermAppearance.statusDone
        case .orchestrating: return TermAppearance.statusWorking
        case .idle: return TermAppearance.statusIdle
        }
    }

    /// 점 모양(색만으로 구분하지 않는다). 모든 표면(사이드바·탭·세션 전환·분할 제목)이 같은 모양을 그린다.
    /// 상태가 없으면(셸·연결 전 claude/codex) 점이 없다 — `dotShape` 가 nil. 점 자리(칸)만 남아 이름이 어긋나지 않는다.
    enum DotShape: Equatable {
        /// 찬 점(작업 중·완료)
        case filled
        /// 속 빈 고리(쉼)
        case ring
        /// 테두리를 두른 점 ◉(입력 대기)
        case ringedDot
        /// 점선 고리 + 가운데 점(오케스트레이션)
        case dottedRing
        /// 찬 점에 "!" 를 뚫은 모양(오류)
        case errorMark
    }

    /// nil = 그리지 않는다(상태 없음)
    var dotShape: DotShape? {
        switch self {
        case .none, .unknown, .codexUnknown: return nil
        case .working, .done: return .filled
        case .idle: return .ring
        case .waiting: return .ringedDot
        case .orchestrating: return .dottedRing
        case .error: return .errorMark
        }
    }

    /// 둘째 줄의 상태 말 색: 사람이 봐야 하는 상태(입력 대기·오류·완료)만 그 상태 색, 나머지는 보조 글자색. 사이드바·세션 전환이 같이 쓴다.
    var wordColor: NSColor { needsAttention ? color : TermAppearance.textSecondary }

    /// 점이 숨 쉬어야 하는가(작업 중·오케스트레이션) — `PulsingDot` / `layer.setWorkingPulse(_:)`
    var pulses: Bool {
        switch self {
        case .working, .orchestrating: return true
        default: return false
        }
    }

    /// 묶음·탭에 대표로 보일 상태(먼저 볼 것부터)
    var rank: Int {
        switch self {
        case .waiting: return 7
        case .error: return 6
        case .done: return 5
        case .working: return 4
        case .orchestrating: return 3
        case .idle: return 2
        case .unknown, .codexUnknown: return 1
        case .none: return 0
        }
    }

    /// 사람이 봐야 하는 상태(알림·Dock 배지)
    var needsAttention: Bool {
        switch self {
        case .waiting, .done, .error: return true
        default: return false
        }
    }

    /// 진단 출력용(`rows`)
    var debugName: String {
        switch self {
        case .none: return "none"
        case .unknown, .codexUnknown: return "unknown"
        case .working: return "working"
        case .waiting(let message): return "waiting" + (message.map { "(\($0))" } ?? "")
        case .done: return "done"
        case .orchestrating(let agents, let shells): return "orchestrating(agents:\(agents),shells:\(shells))"
        case .idle: return "idle"
        case .error(let message): return "error" + (message.map { "(\($0))" } ?? "")
        }
    }

    static func top(_ statuses: [WorkStatus]) -> WorkStatus {
        statuses.max { $0.rank < $1.rank } ?? .none
    }

    /// spaces 접힌 줄의 합계에 셀 종류(상태가 없는 셸·연결 전 claude 는 세션 수에만)
    var summaryKind: SpacesSummary.Kind? {
        switch self {
        case .none, .unknown, .codexUnknown: return nil
        case .working: return .working
        case .waiting: return .waiting
        case .done: return .done
        case .orchestrating: return .orchestrating
        case .idle: return .idle
        case .error: return .error
        }
    }

    /// 합계를 같은 점·색으로 그리려고
    init(summary kind: SpacesSummary.Kind) {
        switch kind {
        case .working: self = .working
        case .waiting: self = .waiting(nil)
        case .done: self = .done
        case .orchestrating: self = .orchestrating(agents: 0, shells: 0)
        case .idle: self = .idle
        case .error: self = .error(nil)
        }
    }
}

/// 세션 종류: 어느 에이전트(또는 화면)인가. 아이콘·종류 색을 한곳에서 정한다 — 사이드바 줄·탭 제목·세션 전환·설정 구역 머리·푸터 사용량 이름표가 같이 쓴다.
/// ✻ claude(주황) · ‹› codex(청록) · ›_ 셸(중립). 문서·브라우저는 중립. 상태에는 쓰지 않는다.
/// claude ✻ 는 SF Symbol 이 없어 선 8갈래로 직접 그린다(`ClaudeMark`) — AppKit 은 `drawIcon`, SwiftUI 는 `SessionKindIcon`.
enum SessionKind: Equatable {
    case claude, codex, shell, document, browser

    var color: NSColor {
        switch self {
        case .claude: return TermAppearance.typeClaude
        case .codex: return TermAppearance.typeCodex
        case .shell: return TermAppearance.typeShell
        case .document, .browser: return TermAppearance.textSecondary
        }
    }

    /// SF Symbol 이름. claude 는 직접 그리므로 nil.
    var symbol: String? {
        switch self {
        case .claude: return nil
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .shell: return "terminal"
        case .document: return "doc.text"
        case .browser: return "globe"
        }
    }

    /// 접근성·도움말 이름
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .shell: return "셸"
        case .document: return "편집기"
        case .browser: return "브라우저"
        }
    }

    /// 상자 안에 아이콘을 그린다(뒤집힌 뷰에서도 바로 선다).
    func drawIcon(size: CGFloat, in box: CGRect) {
        if let symbol {
            SymbolDrawing.draw(symbol, size: size, weight: self == .document ? .regular : .semibold, color: color, centeredIn: box)
            return
        }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = ClaudeMark.lineWidth(side: min(box.width, box.height))
        for (from, to) in ClaudeMark.spokes(in: box) {
            path.move(to: from)
            path.line(to: to)
        }
        color.setStroke()
        path.stroke()
    }
}

/// claude ✻: 가운데에서 뻗는 8갈래 둥근 선. AppKit(`SessionKind.drawIcon`)과 SwiftUI(`SessionKindIcon`)가 같은 선을 쓴다.
struct ClaudeMark: Shape {
    static func lineWidth(side: CGFloat) -> CGFloat { max(1.1, side / 2 * 0.3) }

    static func spokes(in box: CGRect) -> [(CGPoint, CGPoint)] {
        let radius = min(box.width, box.height) / 2
        let width = lineWidth(side: radius * 2)
        return (0..<8).map { spoke in
            let angle = CGFloat(spoke) * .pi / 4
            return (CGPoint(x: box.midX + cos(angle) * radius * 0.2, y: box.midY + sin(angle) * radius * 0.2),
                    CGPoint(x: box.midX + cos(angle) * (radius - width / 2), y: box.midY + sin(angle) * (radius - width / 2)))
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (from, to) in Self.spokes(in: rect) {
            path.move(to: from)
            path.addLine(to: to)
        }
        return path
    }
}

/// SwiftUI 용 종류 아이콘(종류 색). `size` 는 이미 배율을 곱한 pt.
struct SessionKindIcon: View {
    let kind: SessionKind
    let size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        Group {
            if let symbol = kind.symbol {
                // ‹› 는 가로로 가장 넓어(종횡비 1.5) 이름에 붙어 보이므로 한 단계 작게
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .imageScale(kind == .codex ? .small : .medium)
            } else {
                ClaudeMark()
                    .stroke(style: StrokeStyle(lineWidth: ClaudeMark.lineWidth(side: size), lineCap: .round))
                    .frame(width: size, height: size)
                    // 글자와 한 줄에 놓일 때 SF Symbol 처럼 글자 가운데에 오게(바탕선을 아래에서 조금 올린다)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.15 }
            }
        }
        .foregroundStyle(Color(kind.color))
        .accessibilityLabel(kind.label)
    }
}

extension WorkStatus {
    /// AppKit 상태 점(사이드바 `StatusDot` 과 같은 약속 — 탭 제목·세션 전환이 같이 쓴다): 작업 중 = 으뜸 글자색 찬 점(정지 모양),
    /// 입력 대기 = 붉은 고리 + 점(◉), 오류 = 붉은 점에 "!" 도려냄, 끝 = 세이지 찬 점, 쉼 = 회색 고리, 오케스트레이션 = 회색 점선 고리.
    /// 상태가 없거나 아직 모르면 그리지 않는다(`dotShape` nil). rect = 점 상자(8~9pt), cutout = 점 아래 바탕색(! 를 도려낼 때).
    func drawDot(in rect: CGRect, cutout: NSColor) {
        let size = rect.width
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let color = self.color
        switch self {
        case .none, .unknown, .codexUnknown:
            return
        case .idle:
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
        case .waiting:
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        case .orchestrating:
            color.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.setLineDash([1.8, 1.3], count: 2, phase: 0)
            ring.stroke()
        case .error:
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            // "!" 도려내기: 위 막대 + 아래 점
            cutout.setFill()
            let barWidth = max(1.2, size * 0.16)
            NSBezierPath(roundedRect: CGRect(x: center.x - barWidth / 2, y: rect.minY + size * 0.2, width: barWidth, height: size * 0.36),
                         xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            NSBezierPath(ovalIn: CGRect(x: center.x - barWidth / 2, y: rect.minY + size * 0.64, width: barWidth, height: barWidth)).fill()
        case .working:
            // 정지 모양(불투명 1.0). 숨 쉬는 점은 레이어가 맡는다(탭 줄 `TabBarView.syncDotLayers`·사이드바 `PulsingDot`).
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .done:
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

extension PaneRow {
    var sessionKind: SessionKind { isCodex ? .codex : isClaude ? .claude : .shell }
}
