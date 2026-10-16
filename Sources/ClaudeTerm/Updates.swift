import AppKit
import SessionCore
import TermWire

/// 새 버전 알림. 앱을 켤 때와 앞으로 나올 때, 마지막 확인에서 24시간이 지났을 때만 gh 로 최신 릴리스를 본다(그 밖의 주기 확인 없음).
/// 새 버전이 있으면 상태 줄에 한 줄로 알리고, 누르면 업데이트 명령을 보여 준다.
/// 시험용: CLAUDE_TERM_FAKE_LATEST=v0.3.0 이면 gh 대신 그 태그를 최신으로 본다.
final class UpdateNotifier: ObservableObject {
    @Published private(set) var available: UpdateCheck.Release?

    /// 앱 버전(Info.plist). 묶음 없이 띄운 개발 빌드는 nil — 자동 확인을 하지 않는다.
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private let stampURL = TermPaths.home.appendingPathComponent("update-check.json")
    private let fakeLatest = ProcessInfo.processInfo.environment["CLAUDE_TERM_FAKE_LATEST"].flatMap { $0.isEmpty ? nil : $0 }
    private let queue = DispatchQueue(label: "ClaudeTerm.updates", qos: .utility)
    private var checking = false

    func start() {
        // 지난번에 본 최신 릴리스로 먼저 알린다(gh 를 다시 부르지 않고)
        if let current, let latest = UpdateCheck.Stamp.load(from: stampURL)?.latest,
           UpdateCheck.isNewer(latest.tag, than: current) {
            available = latest
        }
        checkIfDue()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.checkIfDue() }
    }

    func checkIfDue() {
        guard current != nil, !checking else { return }
        if let stamp = UpdateCheck.Stamp.load(from: stampURL), !stamp.isDue(), fakeLatest == nil { return }
        check(report: false)
    }

    /// 메뉴 "업데이트 확인…": 바로 확인하고 결과를 알린다
    func checkNow() {
        guard current != nil else {
            report("개발 빌드라 버전을 비교할 수 없습니다", "scripts/build-term-proto.sh 로 만든 앱에서 확인하세요.")
            return
        }
        guard !checking else { return }
        check(report: true)
    }

    private func check(report: Bool) {
        checking = true
        let stampURL = stampURL, fake = fakeLatest
        queue.async { [weak self] in
            let result: Result<UpdateCheck.Release, UpdateCheck.Failure> = fake.map {
                .success(.init(tag: $0, url: "https://github.com/\(UpdateCheck.repository)/releases/tag/\($0)"))
            } ?? UpdateCheck.latestRelease()
            let previous = UpdateCheck.Stamp.load(from: stampURL)
            // 실패해도 시각은 남긴다(gh 가 없거나 오프라인이어도 하루 한 번만 시도)
            let latest = (try? result.get()) ?? previous?.latest
            UpdateCheck.Stamp(checkedAt: Date(), latest: latest).save(to: stampURL)
            DispatchQueue.main.async { self?.finish(result, report: report) }
        }
    }

    private func finish(_ result: Result<UpdateCheck.Release, UpdateCheck.Failure>, report: Bool) {
        checking = false
        guard let current else { return }
        switch result {
        case .success(let release):
            available = UpdateCheck.isNewer(release.tag, than: current) ? release : nil
            if ProcessInfo.processInfo.environment["CLAUDE_TERM_DEBUG"] == "1" {
                print("update latest=\(release.tag) current=\(current) available=\(available?.tag ?? "-")")
                fflush(stdout)
            }
            guard report else { return }
            if available != nil {
                presentUpdate()
            } else {
                self.report("최신 버전입니다", "지금 쓰는 v\(current) 이 가장 새 버전입니다(최신 릴리스 \(Self.display(release.tag))).")
            }
        case .failure(let failure):
            guard report else { return }
            switch failure {
            case .noGh:
                self.report("업데이트를 확인하지 못했습니다",
                            "GitHub CLI(gh)가 없습니다. 터미널에서 `brew install gh` 후 `gh auth login` 으로 로그인하세요.")
            case .failed(let detail):
                self.report("업데이트를 확인하지 못했습니다",
                            "gh 로 \(UpdateCheck.repository) 릴리스를 읽지 못했습니다. 로그인(`gh auth status`)·저장소 초대·네트워크를 확인하세요.\n\n\(detail)")
            }
        }
    }

    /// 상태 줄 "새 버전 … — 업데이트" 를 누르면: 업데이트 명령(복사)과 릴리스 페이지
    func presentUpdate() {
        guard let release = available else { return }
        let command = UpdateCheck.installCommand
        let alert = NSAlert()
        alert.messageText = "새 버전 \(Self.display(release.tag))"
        alert.informativeText = """
            지금 v\(current ?? "?") 을 쓰고 있습니다. 터미널에서 아래 명령을 실행하면 새 버전으로 바꿔 끼웁니다.
            열려 있는 셸·claude 세션은 끊기지 않습니다.
            """
        let field = NSTextField(wrappingLabelWithString: command)
        field.font = TermAppearance.uiFont(11)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 440, height: 48)
        alert.accessoryView = field
        alert.addButton(withTitle: "명령 복사")
        alert.addButton(withTitle: "릴리스 보기")
        alert.addButton(withTitle: "닫기")
        switch AppAlert.run(alert) {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .alertSecondButtonReturn:
            if let url = URL(string: release.url) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func report(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        _ = AppAlert.run(alert)
    }

    static func display(_ tag: String) -> String { tag.hasPrefix("v") ? tag : "v" + tag }
}

/// 확인 창. 시험(CLAUDE_TERM_DEBUG=1)에서는 창을 띄우지 않고 내용을 찍은 뒤, 미리 받은 답(alert-answer)을 쓴다
/// (없으면 마지막 버튼 = 취소·닫기). 시험 앱이 창에 막혀 디버그 명령을 못 받는 일을 막는다.
enum AppAlert {
    static var pendingAnswers: [Int] = []

    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard ProcessInfo.processInfo.environment["CLAUDE_TERM_DEBUG"] == "1" else { return alert.runModal() }
        let buttons = alert.buttons.map(\.title)
        let index = pendingAnswers.isEmpty ? max(buttons.count - 1, 0) : pendingAnswers.removeFirst()
        let accessory = (alert.accessoryView as? NSTextField)?.stringValue
        print("alert \(alert.messageText) | \(alert.informativeText.replacingOccurrences(of: "\n", with: " ⏎ "))"
              + (accessory.map { " | [\($0)]" } ?? "") + " | buttons=\(buttons.joined(separator: "/")) → \(buttons[safe: index] ?? "-")")
        fflush(stdout)
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
