import BrowserCore
import Foundation

/// 에이전트가 브라우저를 쓰기 시작하면 세션 창 안 작은 창을 자동으로 열고, 결과 없이 끝내면 자동으로 닫는다.
/// 결정은 모두 순수 로직(`BrowserCore/BrowserAutoOpen` — `BrowserAutoState`)이 하고, 이 클래스는 신호를 모아 알려 주고
/// 돌려받은 결정을 화면(ToolWindowsController 가 단 클로저)에 옮긴다. 세션(화면 ID)마다 상태가 따로이고 메모리에만 둔다.
/// - 시작 신호: 상태 파일에서 읽은 제어가 agent(잠금 소켓 + 살아 있는 잠금 pid) — `BrowserStatusStore` 가 abx 폴더 쓰기 이벤트
///   (0.15초 모음) 또는 2초 주기로 읽어 `statusChanged` 로 알린다
/// - 끝 신호: `<세션>.done.json`(`doneChanged`) — 상태 읽기와 같은 길
final class BrowserAutoController {
    // MARK: 화면이 다는 것(메인 스레드)

    /// 설정 "에이전트가 브라우저를 쓰면 작은 창 자동으로 열기"
    var setting: () -> Bool = { true }
    /// 그 세션이 브라우저를 세션 창 안 작은 창으로 보는 중인가(별도 창이면 아무것도 하지 않는다)
    var floatPresentation: (String) -> Bool = { _ in false }
    /// 그 세션의 작은 창이 열려 있나(열림 기록 기준 — 지금 보이는 세션이 아니어도)
    var panelOpen: (String) -> Bool = { _ in false }
    /// 세션 목록을 처음 받았는지(받기 전의 빈 상태로 "처음 본 것" 기준을 잡으면, 이미 일하던 에이전트를 새 작업으로 본다)
    var discovered: () -> Bool = { true }
    /// 그 세션의 작은 창을 자동으로 열거나 닫는다(키보드를 가져가지 않고, 보이는 세션이면 부드럽게)
    var setPanel: (String, Bool) -> Void = { _, _ in }
    /// 그 세션의 작은 창에서 탭(targetId)을 보인다
    var showTab: (String, String) -> Void = { _, _ in }
    /// 🌐 알약("결과 있음")이 바뀜
    var onBadgeChanged: (() -> Void)?

    private(set) var states: [String: BrowserAutoState] = [:]
    private let launchedAt: Int64
    private let clock: () -> Int64
    /// 앱을 켠 뒤 첫 상태를 받았나(그 첫 상태는 이미 도는 작업이라 자동으로 열지 않는다)
    private var primed = false
    var isPrimed: Bool { primed }
    private var badgeTimers: [String: DispatchWorkItem] = [:]

    init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
        launchedAt = clock()
    }

    private func context(_ id: String) -> BrowserAutoPolicy.Context {
        BrowserAutoPolicy.Context(setting: setting(), floatPresentation: floatPresentation(id), panelOpen: panelOpen(id))
    }

    /// 자동으로 열거나 닫는다(그 열림·닫힘이 사람이 한 것으로 기록되지 않게 하는 일은 setPanel 을 다는 쪽이 한다)
    private func act(_ id: String, open: Bool) { setPanel(id, open) }

    // MARK: 신호

    /// 브라우저 상태가 바뀜(화면 ID → 상태, 떠 있는 브라우저가 있는 화면만): 에이전트 작업의 시작·끝
    func statusChanged(_ statuses: [String: AbxStatus]) {
        let now = clock()
        for id in Set(statuses.keys).union(states.keys) {
            let phase = BrowserAutoPolicy.phase(of: statuses[id])
            if states[id] == nil, phase != .working { continue } // 한 번도 일하지 않은 세션은 기록하지 않는다
            var state = states[id] ?? BrowserAutoState(launchedAt: launchedAt)
            let panel = state.observe(phase, now: now, context: context(id), baseline: !primed)
            states[id] = state
            if panel == .open {
                act(id, open: true)
                // 열지 못했으면(세션 창이 없는 등) 자동으로 연 것으로 치지 않는다
                if !panelOpen(id) { states[id]?.autoOpened = false }
            }
            if state.badgeUntil == nil, badgeTimers[id] != nil { cancelBadgeTimer(id) }
        }
        if discovered() { primed = true }
        onBadgeChanged?()
    }

    /// done.json 이 바뀜(화면 ID → 내용, 파일이 있는 화면만)
    func doneChanged(_ dones: [String: AbxDone]) {
        let now = clock()
        var changed = false
        for (id, done) in dones {
            var state = states[id] ?? BrowserAutoState(launchedAt: launchedAt)
            let decision = state.done(done, now: now, context: context(id))
            guard decision.handled else { continue }
            states[id] = state
            switch decision.panel {
            case .open:
                act(id, open: true)
                if !panelOpen(id) { states[id]?.autoOpened = false }
            case .close: act(id, open: false)
            case .keep: break
            }
            if let tab = decision.showTab { showTab(id, tab) }
            if decision.badge { scheduleBadgeExpiry(id) }
            changed = true
        }
        if changed { onBadgeChanged?() }
    }

    /// 사람이 세션의 작은 창을 열거나 닫았다(자동이 아닌 열림·닫힘)
    func userToggled(_ id: String, open: Bool) {
        var state = states[id] ?? BrowserAutoState(launchedAt: launchedAt)
        if open { state.userOpened() } else { state.userClosed() }
        states[id] = state
        cancelBadgeTimer(id)
        onBadgeChanged?()
    }

    /// 사람이 창 안을 눌렀거나 제어를 가져왔다
    func userInteracted(_ id: String) {
        var state = states[id] ?? BrowserAutoState(launchedAt: launchedAt)
        let hadBadge = state.badgeUntil != nil
        state.userInteracted(panelOpen: panelOpen(id))
        states[id] = state
        if hadBadge { cancelBadgeTimer(id); onBadgeChanged?() }
    }

    /// 세션 창에서 고른 세션이 id 로 바뀜: 열려 있는 창을 보게 됐으니 결과 알림을 거둔다
    func sessionShown(_ id: String?) {
        guard let id, var state = states[id], state.badgeUntil != nil, panelOpen(id) else { return }
        state.looked()
        states[id] = state
        cancelBadgeTimer(id)
        onBadgeChanged?()
    }

    /// 세션이 닫힘
    func forget(_ id: String) {
        states[id] = nil
        cancelBadgeTimer(id)
    }

    /// 🌐 알약에 "결과 있음"을 보일 때
    func badge(_ id: String?) -> Bool {
        guard let id, let state = states[id] else { return false }
        return state.badge(at: clock())
    }

    private func scheduleBadgeExpiry(_ id: String) {
        cancelBadgeTimer(id)
        let work = DispatchWorkItem { [weak self] in
            self?.badgeTimers[id] = nil
            self?.onBadgeChanged?()
        }
        badgeTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(BrowserAutoPolicy.badgeDuration)) + .milliseconds(50), execute: work)
    }

    private func cancelBadgeTimer(_ id: String) {
        badgeTimers.removeValue(forKey: id)?.cancel()
    }

    // MARK: 시험

    /// 시험 명령 `browser-autostate`: 세션마다 자동 열기·닫기 기록
    var debugSummary: String {
        var lines = ["browser-autostate setting=\(setting() ? "on" : "off") primed=\(primed)"]
        for (id, state) in states.sorted(by: { $0.key < $1.key }) {
            lines.append("browser-autostate \(id.prefix(4)) autoOpened=\(state.autoOpened) dismissed=\(state.dismissedThisRun) "
                + "lastDoneAt=\(state.lastDoneAt.map(String.init) ?? "-") badge=\(state.badge(at: clock())) "
                + "interacted=\(state.userInteracted) agentActive=\(state.agentActive) runStartedAt=\(state.runStartedAt) "
                + "open=\(panelOpen(id)) float=\(floatPresentation(id))")
        }
        return lines.joined(separator: "\n")
    }
}
