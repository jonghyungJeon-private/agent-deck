import AppKit
import SwiftUI
import TermLayout

/// "작업 중" 점의 숨 쉬기 — 모든 점이 한 시계(절대 시각)를 써서 같은 위상으로 숨 쉰다(`WorkingPulseSpec`: 1.0 ↔ 0.55, 1.6초).
/// - 멈추는 때(정지 상태 = 불투명도 1.0): macOS "동작 줄이기", 앱 숨김, 보이는 창이 하나도 없음(가려지거나 최소화).
///   바뀌면 `isRunning`(SwiftUI 갱신)과 `didChange` 알림(AppKit 뷰가 다시 `apply`)이 나간다.
/// - SwiftUI: `PulsingDot`(점 하나가 CALayer). AppKit(CALayer): `layer.setWorkingPulse(isWorking)` — 상태가 바뀔 때와 `didChange` 를 받을 때 부른다.
/// 메인 스레드에서만 쓴다.
final class WorkingPulse: ObservableObject {
    static let shared = WorkingPulse()
    /// 숨 쉬는 중인지가 바뀌었다(동작 줄이기·창 가림·앱 숨김). AppKit 뷰가 받아 `setWorkingPulse` 를 다시 부른다.
    static let didChange = Notification.Name("AgentDeck.workingPulseDidChange")

    /// 지금 숨 쉬어야 하나: 동작 줄이기가 꺼져 있고, 앱이 숨겨지지 않았고, 보이는 창이 있다
    @Published private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let update: (Notification) -> Void = { [weak self] _ in self?.refresh() }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeMainNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didFinishLaunchingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
        // 동작 줄이기는 NSWorkspace 쪽 알림 — 켜고 끄면 바로 반영
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: update))
        refresh()
    }

    /// 지금 상태를 다시 읽는다(알림이 없는 변화가 의심될 때)
    func refresh() {
        let running = Self.shouldRun()
        guard running != isRunning else { return }
        isRunning = running
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func shouldRun() -> Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        guard let app = NSApp, !app.isHidden else { return false }
        return app.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    // MARK: AppKit(CALayer)

    static let animationKey = "workingPulse"

    /// 이 레이어에 붙일 숨 쉬기 애니메이션: 불투명도 1 → 0.55, 0.8초, 오가기, 끝없이 되풀이.
    /// 시작 시각을 주기 배수에 맞춰(`alignedBegin`) 다른 레이어와 위상이 같다.
    func animation(for layer: CALayer) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = WorkingPulseSpec.minOpacity
        animation.duration = WorkingPulseSpec.halfPeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = layer.convertTime(WorkingPulseSpec.alignedBegin(now: CACurrentMediaTime()), from: nil)
        animation.isRemovedOnCompletion = false
        return animation
    }
}

extension CALayer {
    /// 작업 중이면 숨 쉬게, 아니면(또는 멈춰야 하면) 불투명도 1.0 으로 가만히. 이미 같은 상태면 건드리지 않는다.
    func setWorkingPulse(_ working: Bool) {
        let shared = WorkingPulse.shared
        let attached = animation(forKey: WorkingPulse.animationKey) != nil
        if working && shared.isRunning {
            if !attached { add(shared.animation(for: self), forKey: WorkingPulse.animationKey) }
        } else if attached {
            removeAnimation(forKey: WorkingPulse.animationKey)
        }
    }
}

/// SwiftUI: 숨 쉬는 "작업 중" 점. 점은 CALayer 하나이고 숨 쉬기는 레이어 애니메이션(`setWorkingPulse` — GPU 가 돌리고, 시작 시각을 주기 배수에 맞춰
/// 모든 점이 같은 위상)이라 SwiftUI 가 프레임마다 다시 그리지 않는다. 멈춰야 하면(동작 줄이기·창 가림·앱 숨김) 불투명도 1.0 으로 가만히.
struct PulsingDot: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }

    func updateNSView(_ view: PulsingDotView, context: Context) { view.color = color }
}

final class PulsingDotView: NSView {
    var color: NSColor = .white { didSet { applyColor() } }
    private let dot = CALayer()
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        observer = NotificationCenter.default.addObserver(forName: WorkingPulse.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.dot.setWorkingPulse(true)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cg(in: self)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColor()
        dot.setWorkingPulse(true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }
}
