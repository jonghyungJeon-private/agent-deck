import AppKit
import SessionCore
import TermWire

/// 새 버전 알림. 앱을 켤 때·앞으로 나올 때·떠 있는 동안 한 시간마다, 마지막 확인에서 6시간(`UpdateCheck.interval`)이
/// 지났으면 gh 로 최신 릴리스를 본다. 새 버전이 있으면 상태 줄에 한 줄로 알리고(누르면 업데이트 명령), 그 버전을 처음 봤을 때
/// 한 번 macOS 알림도 보낸다(`onNewVersion`, 보낸 태그는 확인 기록의 `announced`).
/// 시험용: AGENTDECK_FAKE_LATEST=v0.3.0 이면 gh 대신 그 태그를 최신으로 본다.
final class UpdateNotifier: ObservableObject {
    @Published private(set) var available: UpdateCheck.Release?
    /// 새 버전을 처음 봤을 때(버전마다 한 번): macOS 알림을 보낸다
    var onNewVersion: ((UpdateCheck.Release) -> Void)?
    /// "지금 업데이트"를 눌렀을 때(앱이 새 탭에서 설치 명령을 돌린다 — TermModel.installUpdate)
    var onInstall: (() -> Void)?
    private var timer: Timer?

    /// 앱 버전(Info.plist). 묶음 없이 띄운 개발 빌드는 nil — 자동 확인을 하지 않는다.
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var stampURL: URL { TermPaths.home.appendingPathComponent("update-check.json") }
    private let fakeLatest = AgentDeckEnv.nonEmpty("FAKE_LATEST")

    /// 앱 안에서 바로 업데이트할 수 있는지: 버전이 있는(묶음으로 만든) 앱이 설치 스크립트가 바꾸는 앱 폴더에 있을 때.
    /// 시험 앱은 AGENTDECK_APPS_DIR(설치 스크립트와 같은 변수)에 두면 된다.
    var canSelfUpdate: Bool {
        current != nil && UpdateCheck.isInstalledLocation(bundlePath: Bundle.main.bundlePath,
                                                          appsDir: ProcessInfo.processInfo.environment["AGENTDECK_APPS_DIR"])
    }
    private let queue = DispatchQueue(label: "AgentDeck.updates", qos: .utility)
    private var checking = false

    func start() {
        // 지난번에 본 최신 릴리스로 먼저 알린다(gh 를 다시 부르지 않고)
        if let current, let latest = UpdateCheck.Stamp.load(from: stampURL)?.latest,
           UpdateCheck.isNewer(latest.tag, than: current) {
            available = latest
            announceIfNew(latest)
        }
        checkIfDue()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.checkIfDue() }
        // 앱이 계속 앞에 있거나 뒤에만 있어도 확인이 밀리지 않게(확인할 때가 됐는지만 보고, gh 는 간격마다 한 번)
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    /// 새 버전을 처음 봤으면 한 번 알린다. 보낸 태그는 확인 기록에 남겨 다시 켜도 같은 버전으로 또 보내지 않는다.
    /// post=false: 사용자가 메뉴로 확인해 업데이트 창을 이미 보는 중 — 알림은 건너뛰고 본 것으로만 남긴다.
    private func announceIfNew(_ release: UpdateCheck.Release, post: Bool = true) {
        var stamp = UpdateCheck.Stamp.load(from: stampURL) ?? UpdateCheck.Stamp(checkedAt: .distantPast, latest: release)
        guard stamp.announced != release.tag else { return }
        stamp.announced = release.tag
        stamp.save(to: stampURL)
        guard post else { return }
        if AgentDeckEnv.isOn("DEBUG") { print("update-notify \(release.tag)"); fflush(stdout) }
        onNewVersion?(release)
    }

    func checkIfDue() {
        guard current != nil, !checking else { return }
        if let stamp = UpdateCheck.Stamp.load(from: stampURL), !stamp.isDue(), fakeLatest == nil { return }
        check(report: false)
    }

    /// 메뉴 "업데이트 확인…": 바로 확인하고 결과를 알린다
    func checkNow() {
        guard current != nil else {
            report("개발 빌드라 버전을 비교할 수 없습니다", "scripts/build-term-proto.sh로 만든 앱에서 확인하세요.")
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
            UpdateCheck.Stamp(checkedAt: Date(), latest: latest, announced: previous?.announced).save(to: stampURL)
            DispatchQueue.main.async { self?.finish(result, report: report) }
        }
    }

    private func finish(_ result: Result<UpdateCheck.Release, UpdateCheck.Failure>, report: Bool) {
        checking = false
        guard let current else { return }
        switch result {
        case .success(let release):
            available = UpdateCheck.isNewer(release.tag, than: current) ? release : nil
            if let available { announceIfNew(available, post: !report) }
            if AgentDeckEnv.isOn("DEBUG") {
                print("update latest=\(release.tag) current=\(current) available=\(available?.tag ?? "-")")
                fflush(stdout)
            }
            guard report else { return }
            if available != nil {
                presentUpdate()
            } else {
                self.report("최신 버전입니다", "지금 쓰는 버전(v\(current))이 가장 새 버전입니다(최신 릴리스 \(Self.display(release.tag))).")
            }
        case .failure(let failure):
            guard report else { return }
            switch failure {
            case .noGh:
                self.report("업데이트를 확인하지 못했습니다",
                            "GitHub CLI(gh)가 없습니다. 터미널에서 brew install gh를 실행한 뒤 gh auth login으로 로그인하세요.")
            case .failed(let detail):
                self.report("업데이트를 확인하지 못했습니다",
                            "gh로 \(UpdateCheck.repository) 릴리스를 읽지 못했습니다. 로그인(gh auth status)·저장소 초대·네트워크를 확인하세요.\n\n\(detail)")
            }
        }
    }

    /// 상태 줄 "새 버전 … — 업데이트"·알림을 누르면: 지금 업데이트(앱 폴더에 설치된 앱만)·업데이트 명령(복사)·릴리스 페이지
    func presentUpdate() {
        guard let release = available else { return }
        let command = UpdateCheck.installCommand
        let selfUpdate = canSelfUpdate
        let alert = NSAlert()
        alert.messageText = "새 버전 \(Self.display(release.tag))"
        alert.informativeText = selfUpdate
            ? """
            지금 쓰는 버전은 v\(current ?? "?")입니다. 지금 업데이트를 누르면 새 탭에서 설치가 진행되고,
            앱이 잠깐 꺼졌다가 새 버전으로 다시 켜집니다. 열려 있는 셸·claude 세션은 끊기지 않습니다.
            직접 하려면 터미널에서 아래 명령을 실행하세요.
            """
            : """
            지금 쓰는 버전은 v\(current ?? "?")입니다. 터미널에서 아래 명령을 실행하면 새 버전으로 바꿉니다.
            열려 있는 셸·claude 세션은 끊기지 않습니다.
            """
        // 명령은 데이터 — 고정폭(보조 크기)으로, 길면 줄바꿈해 높이를 내용에 맞춘다
        let field = NSTextField(wrappingLabelWithString: command)
        field.font = TermAppearance.scaledUIFont(TypeSize.secondary)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 440
        field.frame = NSRect(origin: .zero, size: field.sizeThatFits(NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)))
        alert.accessoryView = field
        if selfUpdate { alert.addButton(withTitle: "지금 업데이트") }
        alert.addButton(withTitle: "명령 복사")
        alert.addButton(withTitle: "릴리스 보기")
        alert.addButton(withTitle: "닫기")
        // 단추 순서: [지금 업데이트] · 명령 복사 · 릴리스 보기 · 닫기
        let index = AppAlert.run(alert).rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue - (selfUpdate ? 1 : 0)
        switch index {
        case -1:
            onInstall?()
        case 0:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case 1:
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

/// 확인 창. 시험(AGENTDECK_DEBUG=1)에서는 창을 띄우지 않고 내용을 찍은 뒤, 미리 받은 답(alert-answer)을 쓴다
/// (없으면 마지막 버튼 = 취소·닫기). 시험 앱이 창에 막혀 디버그 명령을 못 받는 일을 막는다.
enum AppAlert {
    static var pendingAnswers: [Int] = []

    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard AgentDeckEnv.isOn("DEBUG") else { return alert.runModal() }
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
