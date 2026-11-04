import Foundation

/// 작은 터미널 창의 임시 셸. 데몬에는 보통 화면(PTY)과 똑같이 만들되 ID 를 "scratch-<주인 화면 ID>" 로 해서 알아본다.
/// 앱은 데몬 목록을 읽자마자 이 ID 를 따로 떼어(`split`) 세션 목록·탭·배지·알림·상태 추적·되살리기에 들어가지 않게 한다.
/// 주인(에이전트 세션) 하나에 하나이고, ID 에 주인이 들어 있어 앱을 다시 켜도 주인을 찾아 이어 쓴다.
public enum ScratchPane {
    public static let prefix = "scratch-"

    public static func id(owner: String) -> String { prefix + owner }

    public static func isScratch(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// 임시 셸의 주인 화면 ID(임시 셸이 아니면 nil)
    public static func owner(of id: String) -> String? {
        isScratch(id) && id.count > prefix.count ? String(id.dropFirst(prefix.count)) : nil
    }

    /// 목록을 (보통 화면, 임시 셸)로 나눈다. 순서는 그대로.
    public static func split<T>(_ items: [T], id: (T) -> String) -> (regular: [T], scratch: [T]) {
        var regular: [T] = [], scratch: [T] = []
        for item in items { if isScratch(id(item)) { scratch.append(item) } else { regular.append(item) } }
        return (regular, scratch)
    }

    /// 주인이 없는 임시 셸(주인 화면이 닫혔거나 없어짐) — 끝내야 한다
    public static func orphans(_ scratchIds: [String], liveOwners: Set<String>) -> [String] {
        scratchIds.filter { owner(of: $0).map { !liveOwners.contains($0) } ?? true }
    }
}

/// 임시 셸의 "만들라고 보냄 / 끝내라고 보냄" 기록. 데몬 목록(2초마다)보다 앞서 일어나는 일을 놓치지 않으려는 순수 상태.
/// - 만들기: 보낸 뒤 목록에 나타날 때까지(제한 시간 안에서) "있는 셈"으로 본다(같은 셸을 또 만들지 않게).
/// - 끝내기: 목록에 아직 없어도(만들기가 막 큐에 들어간 경우) 끝내라고 보낸다. 끝내라고 보낸 뒤 목록에서 사라질 때까지는
///   목록의 옛 항목을 "있는 셈"으로 치지 않아, 그사이 다시 열면 새로 만든다.
public struct ScratchShellTracker: Equatable {
    private var pending: [String: Date] = [:]
    private var ending: [String: Date] = [:]
    public let timeout: TimeInterval

    public init(timeout: TimeInterval) { self.timeout = timeout }

    /// 만들라고 보냈다
    public mutating func requestCreate(_ id: String, now: Date) { pending[id] = now }

    /// 끝내라고 보낸다(목록에 없어도 늘 보낸다: 만들기가 큐에 있을 수 있다). 만드는 중이던 기록은 지운다.
    public mutating func requestEnd(_ id: String, now: Date) {
        pending[id] = nil
        ending[id] = now
    }

    func isPending(_ id: String, now: Date) -> Bool {
        pending[id].map { now.timeIntervalSince($0) < timeout } ?? false
    }

    func isEnding(_ id: String, now: Date) -> Bool {
        ending[id].map { now.timeIntervalSince($0) < timeout } ?? false
    }

    /// 그 임시 셸이 데몬에 있거나 만드는 중인가
    public func exists(_ id: String, listed: Bool, now: Date) -> Bool {
        if isPending(id, now: now) { return true }
        if isEnding(id, now: now) { return false } // 목록의 항목은 끝나가는 옛 셸
        return listed
    }

    /// 새 목록을 받았다: 나타난 것·시간이 지난 것을 정리한다. 끝나는 중이던 것은 목록에서 사라지면 끝난 것으로 본다.
    public mutating func reconcile(listed: Set<String>, now: Date) {
        let oldPending = Set(ending.keys) // 끝나는 중인 옛 셸이 목록에 있는 것은 새 셸이 나타난 것이 아니다
        pending = pending.filter { (!listed.contains($0.key) || oldPending.contains($0.key)) && now.timeIntervalSince($0.value) < timeout }
        ending = ending.filter { listed.contains($0.key) && now.timeIntervalSince($0.value) < timeout }
    }

    /// 셸이 끝났다는 알림. 끝내라고 한 옛 셸이 막 죽은 것이고 그 뒤 다시 만들라고 했으면 true(다시 만들라고 한 번 더 보내야 한다 —
    /// 옛 셸이 아직 있을 때 보낸 만들기는 데몬이 무시한다).
    public mutating func exited(_ id: String) -> Bool {
        let recreate = pending[id] != nil && ending[id] != nil
        ending[id] = nil
        if !recreate { pending[id] = nil }
        return recreate
    }

    /// 연결이 끊겼다: 큐에 있던 요청은 사라졌으니 기록을 버린다(다시 붙으면 목록이 사실을 알려 준다)
    public mutating func reset() {
        pending = [:]
        ending = [:]
    }
}
