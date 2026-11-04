import Foundation

/// `abx done` 이 남기는 `<stateDir>/<세션>.done.json` — 에이전트가 이번 작업을 끝냈다는 신호.
/// ```
/// {"at":1793761185123,"space":"s1","kept":[…],"keptTabs":[…],"requested":["<targetId>"],"requestedTabs":["t3"],"remainingAgentTabs":1}
/// ```
/// - `requested`: 에이전트가 --keep 으로 사용자에게 남긴 탭(결과). `kept` 는 앱이 고정한 탭·가져온 사용자 탭까지 들어 있어 결정에 쓰지 않는다.
/// - `remainingAgentTabs`: 다른 작업 공간에서 아직 도는 에이전트 작업.
/// abx 는 에이전트 작업이 다시 시작되면(그리고 `abx down`·브라우저 시작 때) 이 파일을 지운다.
public struct AbxDone: Equatable, Sendable {
    /// 쓴 때(ms, abx 의 Date.now())
    public var at: Int64
    public var space: String?
    /// 사용자에게 남긴 탭의 targetId 들(첫 것을 보여 준다)
    public var requested: [String]
    public var requestedTabs: [String]
    public var remainingAgentTabs: Int

    public init(at: Int64, space: String? = nil, requested: [String] = [], requestedTabs: [String] = [], remainingAgentTabs: Int = 0) {
        self.at = at
        self.space = space
        self.requested = requested
        self.requestedTabs = requestedTabs
        self.remainingAgentTabs = remainingAgentTabs
    }

    /// 너그럽게 읽는다: `at` 이 없거나 숫자가 아니면 nil(쓸 수 없는 파일), 나머지는 빠지거나 모양이 달라도 기본값.
    /// `remainingAgentTabs` 가 빠지면 아직 남은 것으로 본다(모르는 채 창을 닫지 않게).
    public static func decode(_ data: Data) -> AbxDone? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = (json["at"] as? NSNumber).flatMap({ Int64(exactly: $0.doubleValue.rounded(.down)) }), at > 0 else { return nil }
        func strings(_ key: String) -> [String] { (json[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty } }
        let remaining = (json["remainingAgentTabs"] as? NSNumber).map { max(Int(truncating: $0), 0) } ?? 1
        return AbxDone(at: at, space: json["space"] as? String, requested: strings("requested"),
                       requestedTabs: strings("requestedTabs"), remainingAgentTabs: remaining)
    }
}

extension AbxStateReader {
    /// `<stateDir>/<세션>.done.json`(없거나 읽을 수 없으면 nil)
    public func done(_ session: AbxSession) -> AbxDone? {
        (try? Data(contentsOf: URL(fileURLWithPath: session.stateDir).appendingPathComponent("\(session.name).done.json")))
            .flatMap(AbxDone.decode)
    }
}

/// 에이전트가 브라우저를 쓰기 시작하면 작은 창을 자동으로 열고, 결과 없이 끝내면 자동으로 닫는 규칙(순수 로직).
/// 화면(ToolWindowsController)은 이 값에 신호(제어 상태·done.json·사람의 열고 닫음·조작)를 알리고 돌려받은 결정대로 한다.
/// 상태는 세션마다 하나, 메모리에만 둔다(저장하는 것은 기존 열림 기록뿐).
public struct BrowserAutoState: Equatable, Sendable {
    /// 에이전트 작업 하나가 도는 중으로 본다(제어가 agent 가 된 뒤 idle·꺼짐으로 돌아가기 전까지)
    public var agentActive = false
    /// 앱이 지금 작업의 시작을 본 때(ms). 이보다 오래된 done.json 은 지난 작업의 것이다. 처음엔 앱을 켠 때.
    public var runStartedAt: Int64
    /// 이 앱이 자동으로 연 창(사람이 열었거나 결과를 남기면 false)
    public var autoOpened = false
    /// 자동으로 연 뒤 사람이 창 안을 눌렀거나 제어를 가져왔다
    public var userInteracted = false
    /// 이번 작업 중에 사람이 창을 닫았다 — 같은 작업에서는 다시 열지 않는다
    public var dismissedThisRun = false
    /// 이미 처리한 done.json 의 `at`
    public var lastDoneAt: Int64?
    /// "결과 있음" 알약을 보일 시각(ms)까지. nil = 없음
    public var badgeUntil: Int64?

    public init(launchedAt: Int64) { runStartedAt = launchedAt }

    public func badge(at now: Int64) -> Bool { badgeUntil.map { now < $0 } ?? false }
}

public enum BrowserAutoPolicy {
    /// "결과 있음" 알약을 보이는 시간
    public static let badgeDuration: Int64 = 60_000
    /// 앱이 작업 시작을 본 때를 이만큼 앞당겨 잡는다 — 상태는 최대 2초 간격으로 읽혀 시작을 늦게 보므로,
    /// 아주 짧은 작업의 done.json 이 "시작보다 오래된 것"으로 버려지지 않게(abx 는 새 작업이 시작되면 옛 파일을 지운다)
    public static let startSlop: Int64 = 3_000

    /// 결정에 필요한 지금 바깥 사정
    public struct Context: Equatable, Sendable {
        /// 설정 "에이전트가 브라우저를 쓰면 작은 창 자동으로 열기"
        public var setting: Bool
        /// 그 세션이 브라우저를 세션 창 안 작은 창으로 보는 중(별도 창이면 false)
        public var floatPresentation: Bool
        /// 그 세션의 작은 창이 열려 있다(열림 기록 기준 — 보이는 세션이 아니어도)
        public var panelOpen: Bool

        public init(setting: Bool, floatPresentation: Bool, panelOpen: Bool) {
            self.setting = setting
            self.floatPresentation = floatPresentation
            self.panelOpen = panelOpen
        }
    }

    public enum Panel: Equatable, Sendable { case keep, open, close }

    /// 제어 상태에서 본 에이전트 작업의 단계
    public enum RunPhase: Equatable, Sendable {
        /// 에이전트가 입력을 쥐고 있다(잠금)
        case working
        /// 아무도 쥐지 않거나 브라우저가 없다 — 작업이 끝났다
        case finished
        /// 사람에게 넘기는 중·사람이 조작 중: 작업은 이어지는 중이라 단계가 바뀌지 않는다
        case other
    }

    /// `AbxStatus`(없으면 떠 있는 브라우저 없음)에서 단계를
    public static func phase(of status: AbxStatus?) -> RunPhase {
        guard let status else { return .finished }
        switch status.control {
        case .agent: return status.running ? .working : .finished
        case .idle: return .finished
        case .user, .switching: return .other
        }
    }

    public struct DoneDecision: Equatable, Sendable {
        /// false = 버렸다(지난 작업의 것이거나 이미 처리함) — 아무것도 바뀌지 않았다
        public var handled: Bool
        public var panel: Panel
        /// 작은 창에서 먼저 보일 탭(targetId)
        public var showTab: String?
        /// 🌐 알약에 "결과 있음"
        public var badge: Bool
    }
}

extension BrowserAutoState {
    /// 제어 상태가 바뀌었다. `baseline` = 앱을 켠 첫 상태(이미 도는 작업이라 새로 시작한 것으로 치지 않는다 — 자동으로 열지 않는다).
    /// 돌려주는 `.open` 은 자동으로 열라는 뜻이고, 그러면 `autoOpened` 가 된다.
    public mutating func observe(_ phase: BrowserAutoPolicy.RunPhase, now: Int64, context: BrowserAutoPolicy.Context,
                                 baseline: Bool = false) -> BrowserAutoPolicy.Panel {
        switch phase {
        case .working:
            guard !agentActive else { return .keep }
            agentActive = true
            runStartedAt = now - BrowserAutoPolicy.startSlop
            badgeUntil = nil // 새 작업이 시작되면 지난 결과 알림은 거둔다
            guard !baseline, !context.panelOpen, context.setting, context.floatPresentation, !dismissedThisRun else { return .keep }
            autoOpened = true
            userInteracted = false
            return .open
        case .finished:
            guard agentActive else { return .keep }
            agentActive = false
            dismissedThisRun = false // 작업이 끝났다: 다음 작업에서는 다시 열 수 있다
            return .keep
        case .other:
            return .keep
        }
    }

    /// 사람이 작은 창을 열었다(🌐·⌘⇧B…): 자기 창이다 — 자동으로 닫지 않는다. 결과 알림도 거둔다(보는 중).
    public mutating func userOpened() {
        autoOpened = false
        badgeUntil = nil
    }

    /// 사람이 작은 창을 닫았다. 작업이 도는 중이면 같은 작업에서는 다시 열지 않는다.
    public mutating func userClosed() {
        autoOpened = false
        badgeUntil = nil
        if agentActive { dismissedThisRun = true }
    }

    /// 사람이 창 안을 눌렀거나 제어를 가져왔다(보기만 한 것은 아님)
    public mutating func userInteracted(panelOpen: Bool) {
        guard panelOpen else { return }
        userInteracted = true
        badgeUntil = nil
    }

    /// 이 세션이 화면에 나타났고 작은 창이 열려 있다(보는 중): 결과 알림을 거둔다
    public mutating func looked() { badgeUntil = nil }

    /// done.json 을 받았다. 지난 작업의 것(`at` 이 작업 시작보다 오래됨)이거나 이미 처리한 것이면 `handled == false`.
    public mutating func done(_ done: AbxDone, now: Int64, context: BrowserAutoPolicy.Context) -> BrowserAutoPolicy.DoneDecision {
        let ignored = BrowserAutoPolicy.DoneDecision(handled: false, panel: .keep, showTab: nil, badge: false)
        guard done.at >= runStartedAt, done.at > (lastDoneAt ?? 0) else { return ignored }
        lastDoneAt = done.at
        dismissedThisRun = false // 신호가 왔다: 이번 작업의 닫음 기록은 거둔다

        if let tab = done.requested.first {
            // 사용자에게 남긴 결과: 열어 둔 창은 그대로 두고, 닫혀 있고 자동 열기가 켜져 있으면 연다. 첫 탭을 보인다.
            badgeUntil = now + BrowserAutoPolicy.badgeDuration
            var panel = BrowserAutoPolicy.Panel.keep
            if context.floatPresentation, !context.panelOpen, context.setting { panel = .open }
            let shows = context.floatPresentation && (context.panelOpen || context.setting)
            // 결과를 남긴 창은 이제 사람이 볼 것이라 자동으로 닫지 않는다
            autoOpened = false
            if panel == .open { userInteracted = false }
            return BrowserAutoPolicy.DoneDecision(handled: true, panel: panel, showTab: shows ? tab : nil, badge: true)
        }
        // 보여 줄 것이 없다: 자동으로 열었고 사람이 건드리지 않았고 다른 일도 없으면 닫는다
        if done.remainingAgentTabs == 0, autoOpened, !userInteracted, context.panelOpen, context.floatPresentation {
            autoOpened = false
            return BrowserAutoPolicy.DoneDecision(handled: true, panel: .close, showTab: nil, badge: false)
        }
        return BrowserAutoPolicy.DoneDecision(handled: true, panel: .keep, showTab: nil, badge: false)
    }
}
