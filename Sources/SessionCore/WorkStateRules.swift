import Darwin
import Foundation

/// 작업 상태를 화면에 보일 때의 보완 규칙(앱이 쓰는 순수 로직 — 시험하려고 SessionCore 에 둔다).
public enum WorkStateRules {
    /// 입력 대기 시각보다 이만큼 넘게 뒤에 대화 파일이 바뀌면 다시 일하는 것으로 본다
    public static let resumeGrace: TimeInterval = 2

    /// 화면에서 확인한 상태(완료)의 표시. 번호(stateSeq)가 있으면 번호로, 없으면(예전 기록) 시각으로 비교한다.
    public struct Seen: Equatable {
        public var seq: Int?
        public var at: Date

        public init(seq: Int?, at: Date) {
            self.seq = seq
            self.at = at
        }
    }

    /// 지금 상태(번호·시각)를 이미 확인했는가. 같은 초에 새로 온 완료도 번호가 다르면 확인 전이다.
    public static func isSeen(_ seen: Seen?, seq: Int?, at: Date) -> Bool {
        guard let seen else { return false }
        if let seq, let seenSeq = seen.seq { return seenSeq >= seq }
        return seen.at >= at
    }

    /// 기록된 상태(hook 이 적은 state)에 보완 판단을 더한 상태.
    /// - 입력 대기 뒤에 대화 파일이 늘었으면(권한을 허락해 이어서 일함) "working"
    /// - 화면에서 이미 확인한 완료면 "idle"
    public static func effective(state: String?, at: Date?, seq: Int? = nil, transcriptModifiedAt: Date?,
                                 seen: Seen?) -> String? {
        guard let state, let at else { return state }
        if state == "waiting", let modified = transcriptModifiedAt, modified.timeIntervalSince(at) > resumeGrace {
            return "working"
        }
        if state == "done", isSeen(seen, seq: seq, at: at) { return "idle" }
        return state
    }

    /// 대화 파일 수정 시각(stat 한 번, 파일을 읽지 않는다). 이름 정하기와 상관없이 쓴다.
    public static func transcriptModifiedAt(_ path: String?) -> Date? {
        guard let path else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let spec = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    /// 같은 알림을 두 번 보내지 않으려는 열쇠. 상태 번호가 있으면 "세션#번호"(상태를 적을 때마다 바뀜),
    /// 없으면(예전 기록) "상태@시각" — 같은 초라도 상태가 다르면(입력 대기 → 완료) 다른 알림이다.
    public static func notificationKey(sessionId: String, seq: Int?, state: String, at: Date) -> String {
        if let seq { return "\(sessionId)#\(seq)" }
        return "\(state)@\(at.timeIntervalSince1970)"
    }
}
