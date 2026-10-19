import AppKit
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

    var color: NSColor {
        switch self {
        case .none: return TermAppearance.textDim.withAlphaComponent(0.6)
        case .unknown: return TermAppearance.claudeColor
        case .codexUnknown: return TermAppearance.codexColor
        case .working: return TermAppearance.yellow
        case .waiting, .error: return TermAppearance.red
        case .done: return TermAppearance.cyan
        case .orchestrating: return TermAppearance.purple
        case .idle: return TermAppearance.green
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
