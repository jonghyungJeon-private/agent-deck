import Foundation

/// 작은 창을 끌어 옮기거나 크기를 바꾸는 동안 자동 배치(목록 갱신·호스트 크기 변화·브라우저 열림에 따른 터미널 기본 자리…)가
/// 그 창의 자리를 저장된·기본 자리로 되돌리지 않게 막는 순수 규칙. 끌기 시작(`begin`)부터 끝(`end`)까지 그 창의 자동 배치 요청은
/// 미뤄 두고, 끝나면 한 번만 돌려준다. 창마다(키) 따로 센다 — 한 창을 끄는 동안 다른 창의 배치는 막지 않는다.
public struct FloatLayoutGate<Key: Hashable>: Equatable {
    private var gesturing: Set<Key> = []
    private var pending: Set<Key> = []

    public init() {}

    public func isGesturing(_ key: Key) -> Bool { gesturing.contains(key) }
    public func hasPending(_ key: Key) -> Bool { pending.contains(key) }

    /// 끌기 시작
    public mutating func begin(_ key: Key) { gesturing.insert(key) }

    /// 자동 배치를 지금 해도 되는가. 끄는 중이면 false 를 돌려주고 끝난 뒤로 미룬다.
    public mutating func allowsAutoLayout(_ key: Key) -> Bool {
        guard gesturing.contains(key) else { return true }
        pending.insert(key)
        return false
    }

    /// 끌기 끝(또는 끌던 창이 사라짐). 그사이 미룬 자동 배치가 있었으면 true — 한 번 돌리면 된다.
    @discardableResult
    public mutating func end(_ key: Key) -> Bool {
        gesturing.remove(key)
        return pending.remove(key) != nil
    }
}
