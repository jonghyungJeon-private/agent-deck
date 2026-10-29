import AppKit
import BrowserCore
import SwiftUI
import TermWire

/// "Chrome 로그인 가져오기…"(셸 메뉴): 사용자의 Chrome 에서 고른 사이트의 로그인 상태(쿠키)를 에이전트 브라우저로 가져온다.
/// 사용자가 사이트를 고르고 누를 때만, 그때 한 번 키체인(Chrome Safe Storage)을 묻는다. 비밀번호는 가져오지 않는다.
/// 넣는 곳: 로그인 템플릿(새로 여는 화면의 브라우저가 복사해 시작) + 지금 떠 있는 에이전트 브라우저들.
final class ChromeImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var profiles: [ChromeImport.Profile] = []
    @Published var profileId: String? { didSet { if profileId != oldValue { loadSites() } } }
    @Published private(set) var sites: [ChromeImport.Site] = []
    @Published var selected: Set<String> = []
    @Published var search = ""
    @Published private(set) var phase: Phase = .idle
    /// 가져오는 중(목록 읽기와 따로 — 창을 닫았다 열어도 두 번 돌지 않게)
    @Published private(set) var importing = false
    @Published private(set) var loading = false
    /// macOS 가 Chrome 폴더를 막아 전체 디스크 접근 권한이 필요하다
    @Published private(set) var needsDiskAccess = false

    /// 시험용: 가짜 Chrome 폴더(AGENTDECK_CHROME_ROOT)와 그 폴더용 암호(AGENTDECK_CHROME_TEST_PASSWORD — 폴더를 바꿨을 때만 쓴다)
    private let root: URL
    private let testPassword: String?
    /// 지금 떠 있는 에이전트 브라우저들의 CDP 주소(메인 스레드에서 묻는다)
    private let runningBrowsers: () -> [URL]
    private let helpers: URL
    private let queue = DispatchQueue(label: "AgentDeck.chrome-import", qos: .userInitiated)

    init(runningBrowsers: @escaping () -> [URL], helpers: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let override = AgentDeckEnv.nonEmpty("CHROME_ROOT", in: environment)
        root = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ChromeImport.defaultRoot
        testPassword = override == nil ? nil : AgentDeckEnv.nonEmpty("CHROME_TEST_PASSWORD", in: environment)
        self.runningBrowsers = runningBrowsers
        self.helpers = helpers
    }

    var busy: Bool { importing || loading }

    var visibleSites: [ChromeImport.Site] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        return term.isEmpty ? sites : sites.filter { $0.id.contains(term) }
    }

    func reload() {
        let root = self.root
        queue.async { [weak self] in
            let found = ChromeImport.profiles(root: root)
            let blocked = found.isEmpty && ChromeImport.accessBlocked(root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.profiles = found
                self.needsDiskAccess = blocked
                if blocked {
                    self.sites = []
                    self.phase = .failed("macOS 가 Chrome 데이터 읽기를 막았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서 "
                                         + "AgentDeck 을 켠 뒤 [다시 확인]을 누르세요(안 되면 AgentDeck 을 다시 여세요).")
                } else if found.isEmpty {
                    self.sites = []
                    self.phase = .failed("Chrome 프로필을 찾지 못했습니다(\((root.path as NSString).abbreviatingWithTildeInPath)).")
                } else if self.profileId == nil || !found.contains(where: { $0.id == self.profileId }) {
                    self.profileId = found.first?.id
                } else {
                    self.loadSites()
                }
            }
        }
    }

    private var profile: ChromeImport.Profile? { profiles.first { $0.id == profileId } }

    private func loadSites() {
        guard let profile, !importing else { return }
        selected = []
        loading = true
        phase = .working("사이트 목록을 읽는 중…")
        queue.async { [weak self] in
            let result = Result { try ChromeImport.sites(profile: profile.dir) }
            DispatchQueue.main.async {
                guard let self, self.profileId == profile.id else { return }
                self.loading = false
                switch result {
                case .success(let sites):
                    self.sites = sites
                    self.phase = .idle
                case .failure(let error):
                    self.sites = []
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 고른 사이트를 가져온다(누를 때만). 키체인 확인 창이 뜬다.
    func importSelected() {
        guard let profile, !selected.isEmpty, !busy else { return }
        let sites = selected
        let running = runningBrowsers()
        let testPassword = self.testPassword
        let helpers = self.helpers
        importing = true
        phase = .working("키체인에서 Chrome 암호를 읽는 중… (macOS 확인 창에서 허용하세요)")
        let report = MainThreadSink { [weak self] (phase: Phase) in
            self?.phase = phase
            if case .working = phase { return }
            self?.importing = false
        }
        Task.detached(priority: .userInitiated) {
            do {
                let key = try testPassword.map { ChromeImport.deriveKey(password: Data($0.utf8)) } ?? ChromeImport.safeStorageKey()
                let picked = try ChromeImport.cookies(profile: profile.dir, sites: sites, key: key)
                guard !picked.cookies.isEmpty else {
                    report.send(.failed("고른 사이트에서 가져올 쿠키를 풀지 못했습니다(\(picked.skipped)개)."))
                    return
                }
                report.send(.working("로그인 템플릿에 넣는 중…"))
                // 템플릿을 복사해 새로 띄우는 브라우저는 세션 쿠키를 되살리지 않으므로 템플릿에는 7일 쿠키로 넣는다
                let kept = ChromeImport.keepingSessions(picked.cookies, for: 7 * 24 * 3600)
                let template = try await Self.injectIntoTemplate(ChromeImport.cdpCookies(kept), helpers: helpers)
                let params = ChromeImport.cdpCookies(picked.cookies)
                var live = 0, missed = 0
                for endpoint in running {
                    // 하나도 넣지 못한 브라우저(연결 끊김·전부 거절)는 넣었다고 세지 않는다
                    if let r = try? await ChromeImport.inject(params, into: endpoint), r.set > 0 { live += 1 } else { missed += 1 }
                }
                var message = "\(sites.count)개 사이트의 로그인(쿠키 \(template.set)개)을 가져왔습니다. 새로 여는 화면의 브라우저부터 로그인된 채로 시작합니다"
                message += live > 0 ? " — 지금 떠 있는 브라우저 \(live)개에도 넣었습니다." : "."
                if missed > 0 { message += " 떠 있는 브라우저 \(missed)개에는 넣지 못했습니다(새로 열면 로그인돼 있습니다)." }
                if picked.skipped + template.rejected > 0 {
                    message += " 쿠키 \(picked.skipped + template.rejected)개는 풀거나 넣지 못해 뺐습니다."
                }
                report.send(.done(message))
            } catch {
                report.send(.failed(error.localizedDescription))
            }
        }
    }

    /// 로그인 템플릿을 비운다(가져온 로그인을 새 화면에 더는 쓰지 않음). 이미 만든 화면의 브라우저는 그대로.
    func clearTemplate() {
        guard !busy else { return }
        let template = BrowserBinding.templateDir()
        do {
            guard FileManager.default.fileExists(atPath: template.path) else {
                phase = .done("로그인 템플릿이 이미 비어 있습니다.")
                return
            }
            // Chrome 이 템플릿을 쓰는 중(가져오기 도중)이면 지우지 않는다
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: template.appendingPathComponent("SingletonLock").path)) == nil else {
                phase = .failed("로그인 템플릿을 브라우저가 쓰는 중이라 비우지 못했습니다.")
                return
            }
            try FileManager.default.removeItem(at: template)
            phase = .done("로그인 템플릿을 비웠습니다. 새로 여는 화면의 브라우저는 로그아웃 상태로 시작합니다(이미 열린 화면은 그대로).")
        } catch {
            phase = .failed("로그인 템플릿을 비우지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 로그인 템플릿에 넣는다. 새 화면은 abx 가 템플릿을 복사해 시작하므로(ABX_PROFILE_TEMPLATE) 템플릿을 그 자리에서 고치지 않고,
    /// 지금 템플릿의 복사본(작업 폴더)을 브라우저로 잠깐 띄워(창 없이) 쿠키를 넣고 끈 뒤(브라우저가 자기 방식으로 저장) 바꿔 끼운다 —
    /// 고치는 도중의 템플릿을 새 화면이 복사하거나, 템플릿이 잠겨 새 화면 브라우저가 못 뜨는 일이 없게.
    private static func injectIntoTemplate(_ params: [[String: Any]], helpers: URL) async throws -> (set: Int, rejected: Int) {
        guard let runner = AbxRunner.locate(bundleHelpers: helpers) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "abx 를 찾지 못했습니다"])
        }
        let fm = FileManager.default
        let template = BrowserBinding.templateDir()
        let profiles = template.deletingLastPathComponent()
        let token = UUID().uuidString
        let work = profiles.appendingPathComponent(".template-next-\(token)", isDirectory: true)
        try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        if fm.fileExists(atPath: template.path) {
            try fm.copyItem(at: template, to: work) // 앞서 가져온 로그인도 이어 간다
        }
        let session = AbxSession(name: "ad-template", socketDir: BrowserBinding.socketDir().path,
                                 stateDir: BrowserBinding.stateDir().path, profileDir: work.path)
        var env = ["ABX_HEADLESS": "1", "ABX_LOCK_INPUT": "0", "ABX_PROFILE_TEMPLATE": "",
                   "ABX_BROWSERS_DIR": BrowserBinding.browsersDir().path]
        if let browser = BrowserBinding.explicitBrowser() { env["ABX_BROWSER"] = browser }
        let result: (set: Int, rejected: Int)
        do {
            let up = try runner.run(["up", "--headless"], session: session, extraEnvironment: env, timeout: 60)
            guard up.status == 0, let endpoint = AbxStateReader().status(session).cdpUrl.flatMap(URL.init(string:)) else {
                let detail = String(data: up.output, encoding: .utf8)?.split(separator: "\n").first.map(String.init) ?? "종료 코드 \(up.status)"
                throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "템플릿 브라우저를 띄우지 못했습니다: \(detail)"])
            }
            result = try await ChromeImport.inject(params, into: endpoint)
        } catch {
            _ = try? runner.run(["down"], session: session, extraEnvironment: env, timeout: 30) // 시간 초과로 끊긴 시작도 정리
            throw error
        }
        // 끈 뒤에야 쿠키가 파일에 다 쓰인다. 꺼지지 않았으면 바꿔 끼우지 않는다.
        let down = try runner.run(["down"], session: session, extraEnvironment: env, timeout: 30)
        let locked = (try? fm.destinationOfSymbolicLink(atPath: work.appendingPathComponent("SingletonLock").path)) != nil
        guard down.status == 0, !locked else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "템플릿 브라우저를 끄지 못해 로그인 템플릿을 바꾸지 않았습니다"])
        }
        guard result.set > 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "브라우저가 쿠키를 하나도 받지 않아(\(result.rejected)개 거절) 로그인 템플릿을 바꾸지 않았습니다"])
        }
        // 한 번에 바꿔 끼운다(RENAME_SWAP) — 템플릿 자리가 비는 순간에 새 화면이 빈 프로필로 시작하지 않게.
        // 바꾼 뒤 work 자리에 남은 예전 템플릿은 위 defer 가 지운다.
        if fm.fileExists(atPath: template.path) {
            guard renamex_np(work.path, template.path, UInt32(RENAME_SWAP)) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "로그인 템플릿을 바꾸지 못했습니다: \(String(cString: strerror(errno)))"])
            }
        } else {
            try fm.moveItem(at: work, to: template)
        }
        return result
    }
}

struct ChromeImportView: View {
    @ObservedObject var model: ChromeImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chrome 로그인 가져오기").font(.headline)
            Text("고른 사이트의 로그인 상태(쿠키)만 에이전트 브라우저로 가져옵니다. 비밀번호는 가져오지 않습니다. "
                 + "가져오면 에이전트가 그 사이트에 로그인된 채로 접속합니다 — 은행·메일처럼 맡기기 어려운 사이트는 고르지 마세요. "
                 + "가져올 때 macOS 가 키체인의 \"Chrome Safe Storage\" 사용을 묻습니다. "
                 + "가져온 로그인은 AgentDeck 브라우저 프로필에 저장되며 키체인이 아닌 파일 권한으로만 보호됩니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.profiles.count > 1 {
                Picker("Chrome 프로필", selection: $model.profileId) {
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(model.busy)
            }
            HStack {
                TextField("사이트 검색 (예: charancha)", text: $model.search).textFieldStyle(.roundedBorder)
                Text("\(model.selected.count)개 고름").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("선택 해제") { model.selected = [] }.disabled(model.selected.isEmpty || model.busy)
            }
            List(model.visibleSites) { site in
                Toggle(isOn: Binding(get: { model.selected.contains(site.id) },
                                     set: { on in if on { model.selected.insert(site.id) } else { model.selected.remove(site.id) } })) {
                    HStack {
                        Text(site.id)
                        Spacer()
                        Text("쿠키 \(site.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busy)
            }
            .frame(minHeight: 220)
            status
            if model.needsDiskAccess {
                HStack {
                    Button("전체 디스크 접근 권한 설정 열기") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("다시 확인") { model.reload() }
                }
            }
            HStack {
                Button("로그인 템플릿 비우기") { model.clearTemplate() }
                    .disabled(model.busy)
                    .help("가져온 로그인을 새 화면에 더는 쓰지 않습니다(이미 열린 화면의 브라우저는 그대로).")
                Spacer()
                Button("가져오기") { model.importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty || model.busy)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 460)
        .onAppear { model.reload() }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .working(let text):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }.font(.system(size: 11))
        case .done(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Color(TermAppearance.accent)).fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Color(TermAppearance.red)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 창(한 번 만들어 두고 닫아도 다시 쓴다)
final class ChromeImportWindowController {
    private var window: NSWindow?
    let model: ChromeImportModel

    init(model: ChromeImportModel) { self.model = model }

    var windowNumber: Int? { window?.windowNumber }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: ChromeImportView(model: model).environment(\.colorScheme, .dark))
            host.view.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentViewController: host)
            window.title = "Chrome 로그인 가져오기"
            window.styleMask = [.titled, .closable, .resizable]
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = TermAppearance.chrome
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 560))
            window.center()
            window.setFrameAutosaveName("AgentDeckChromeImport")
            self.window = window
        } else {
            model.reload()
        }
        if AgentDeckEnv.isOn("NO_ACTIVATE") { window?.orderFront(nil) } else { window?.makeKeyAndOrderFront(nil) }
    }
}
