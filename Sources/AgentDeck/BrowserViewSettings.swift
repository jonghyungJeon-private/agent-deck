import BrowserCore
import Foundation
import TermWire

/// 브라우저 화면 설정(선명도·데스크톱 유지)을 들고 `term/browser-view.json` 에 쓴다. 바뀌면 열린 브라우저 화면들에 알린다.
final class BrowserViewSettings: ObservableObject {
    static let shared = BrowserViewSettings()
    /// object = 새 BrowserViewOptions
    static let changed = Notification.Name("AgentDeck.browserViewOptionsChanged")

    @Published var options: BrowserViewOptions {
        didSet {
            guard options != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Self.changed, object: options)
        }
    }

    static var url: URL { TermPaths.home.appendingPathComponent("browser-view.json") }

    private init() {
        options = BrowserViewOptions.load(from: Self.url)
    }

    private func save() {
        guard let data = options.data() else { return }
        try? FileManager.default.createDirectory(at: TermPaths.home, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
