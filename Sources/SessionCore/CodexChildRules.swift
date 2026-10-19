import Foundation

public enum CodexChildRules {
    public static let finishedRetention: TimeInterval = 15 * 60
    public static let abandonedRetention: TimeInterval = 24 * 60 * 60

    public enum Activity: Equatable {
        case running, stopped
    }

    /// 작업 중이면 상태의 나이로 버리지 않는다. 파일도 하루 동안 멈춘 기록만 제외한다.
    public static func activity(state: String?, stateAt: Date?, edgeStatus: String,
                                lastActivityAt: Date?, now: Date = Date()) -> Activity? {
        if let lastActivityAt,
           now.timeIntervalSince(max(lastActivityAt, stateAt ?? .distantPast)) >= abandonedRetention { return nil }
        let working = ["working", "inProgress", "in_progress", "running"].contains(state ?? "")
        let closed = edgeStatus == "closed"
        let finished = closed || ["done", "completed", "idle", "error", "interrupted", "aborted", "failed"].contains(state ?? "")
        if finished, now.timeIntervalSince(stateAt ?? .distantPast) >= finishedRetention { return nil }
        return working && !closed ? .running : .stopped
    }
}
