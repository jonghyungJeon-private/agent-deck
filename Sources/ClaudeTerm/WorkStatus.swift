import AppKit

/// claude 화면의 작업 상태(hook 기록에서). 색만으로 구분하지 않도록 글자도 함께 보인다.
enum WorkStatus: Equatable {
    /// claude 가 아니다
    case none
    /// claude 인데 상태 hook 이 아직 없다(연결 갱신 전)
    case unknown
    case working
    /// 권한·질문 등 사람의 입력을 기다린다
    case waiting(String?)
    /// 응답을 마쳤고 아직 안 봤다
    case done
    case idle
    case error(String?)

    init(state: String?, message: String?) {
        switch state {
        case "working": self = .working
        case "waiting": self = .waiting(message)
        case "done": self = .done
        case "idle": self = .idle
        case "error": self = .error(message)
        default: self = .unknown
        }
    }

    var label: String? {
        switch self {
        case .none, .unknown: return nil
        case .working: return "작업 중"
        case .waiting: return "입력 대기"
        case .done: return "완료"
        case .idle: return "쉬는 중"
        case .error: return "오류"
        }
    }

    var detail: String? {
        switch self {
        case .waiting(let message), .error(let message): return message
        default: return nil
        }
    }

    var color: NSColor {
        switch self {
        case .none: return TermAppearance.textDim.withAlphaComponent(0.6)
        case .unknown: return TermAppearance.claudeColor
        case .working: return TermAppearance.yellow
        case .waiting, .error: return TermAppearance.red
        case .done: return TermAppearance.cyan
        case .idle: return TermAppearance.green
        }
    }

    /// 묶음·탭에 대표로 보일 상태(먼저 볼 것부터)
    var rank: Int {
        switch self {
        case .waiting: return 6
        case .error: return 5
        case .done: return 4
        case .working: return 3
        case .idle: return 2
        case .unknown: return 1
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
        case .unknown: return "unknown"
        case .working: return "working"
        case .waiting(let message): return "waiting" + (message.map { "(\($0))" } ?? "")
        case .done: return "done"
        case .idle: return "idle"
        case .error(let message): return "error" + (message.map { "(\($0))" } ?? "")
        }
    }

    static func top(_ statuses: [WorkStatus]) -> WorkStatus {
        statuses.max { $0.rank < $1.rank } ?? .none
    }
}
