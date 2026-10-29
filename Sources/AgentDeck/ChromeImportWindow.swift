import AppKit
import BrowserCore
import SwiftUI
import TermWire

/// "Chrome 로그인 가져오기…"(셸 메뉴): 사용자의 Chrome 에서 고른 사이트의 로그인 상태(쿠키)를 에이전트 브라우저로 가져온다.
/// 사용자가 사이트를 고르고 누를 때만, 그때 한 번 키체인(Chrome Safe Storage)을 묻는다. 비밀번호는 가져오지 않는다.
/// 넣는 곳: 로그인 템플릿(새로 여는 화면의 브라우저가 복사해 시작) + 이미 있는 화면의 브라우저 프로필 모두
/// (떠 있으면 그 브라우저에 바로, 꺼져 있으면 잠깐 띄워 넣고 끈다).
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
    private let helpers: URL
    private let queue = DispatchQueue(label: "AgentDeck.chrome-import", qos: .userInitiated)

    init(helpers: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let override = AgentDeckEnv.nonEmpty("CHROME_ROOT", in: environment)
        root = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ChromeImport.defaultRoot
        testPassword = override == nil ? nil : AgentDeckEnv.nonEmpty("CHROME_TEST_PASSWORD", in: environment)
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
                report.send(.working("이미 있는 화면의 브라우저에 넣는 중…"))
                let panes = await Self.injectIntoPanes(live: ChromeImport.cdpCookies(picked.cookies), offline: ChromeImport.cdpCookies(kept),
                                                       helpers: helpers)
                var message = "\(sites.count)개 사이트의 로그인(쿠키 \(template.set)개)을 가져왔습니다. 새로 여는 화면의 브라우저부터 로그인된 채로 시작합니다"
                let done = [panes.live > 0 ? "떠 있는 브라우저 \(panes.live)개" : nil, panes.offline > 0 ? "꺼져 있던 화면 \(panes.offline)개" : nil]
                    .compactMap { $0 }
                message += done.isEmpty ? "." : " — 이미 있는 화면에도 넣었습니다(\(done.joined(separator: ", ")))."
                if panes.missed > 0 { message += " 화면 \(panes.missed)개에는 넣지 못했습니다(사람이 조작 중이거나 브라우저를 띄우지 못함)." }
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

    /// 이미 있는 화면의 브라우저 프로필(`abx-profiles/ad-*`)마다 넣는다. 떠 있으면 그 브라우저에 바로(`live`), 꺼져 있으면
    /// 그 프로필을 임시 세션(`ai-…`)으로 창 없이 잠깐 띄워 넣고 끈다(`offline` — 다시 띄우면 세션 쿠키가 사라지므로 7일 쿠키).
    /// 꺼진 화면은 그 화면 세션의 writer 자리를 잡고 한다(그동안 에이전트 동작은 기다림). 임시 세션이라 그 사이 에이전트가 조회하려고
    /// 띄운 브라우저를 끄지 않고, 브라우저는 그 화면이 쓰던 판으로 띄운다(새 판이 프로필을 올리면 옛 판이 못 연다).
    /// 화면 하나는 abx 가 오래된 자리로 보고 되찾는 120초 안에 끝낸다. 사람이 조작 중(handoff)인 화면은 건너뛴다.
    private static func injectIntoPanes(live: [[String: Any]], offline: [[String: Any]], helpers: URL) async -> (live: Int, offline: Int, missed: Int) {
        let fm = FileManager.default
        let profiles = BrowserBinding.templateDir().deletingLastPathComponent()
        let names = ((try? fm.contentsOfDirectory(atPath: profiles.path)) ?? []).filter { $0.hasPrefix("ad-") }.sorted()
        let runner = AbxRunner.locate(bundleHelpers: helpers)
        let socketDir = BrowserBinding.socketDir().path, stateDir = BrowserBinding.stateDir().path
        var counts = (live: 0, offline: 0, missed: 0)
        func injectLive(_ status: AbxStatus, deadline: Date = .distantFuture) async {
            // 하나도 넣지 못한 브라우저(연결 끊김·전부 거절)는 넣었다고 세지 않는다
            if let url = status.cdpUrl.flatMap(URL.init(string:)), let r = try? await ChromeImport.inject(live, into: url, deadline: deadline),
               r.set > 0 {
                counts.live += 1
            } else {
                counts.missed += 1
            }
        }
        for name in names {
            let profile = profiles.appendingPathComponent(name)
            let pane = AbxSession(name: name, socketDir: socketDir, stateDir: stateDir, profileDir: profile.path)
            let status = AbxStateReader().status(pane)
            if status.running {
                await injectLive(status)
                continue
            }
            guard let runner, status.handoff == nil, let lease = AbxWriterLease.acquire(stateDir: stateDir, session: name, wait: 5) else {
                counts.missed += 1
                continue
            }
            defer { lease.release() }
            let started = Date()
            // 자리를 잡는 사이 에이전트가 띄웠으면 그 브라우저에 넣는다
            let now = AbxStateReader().status(pane)
            if now.running {
                await injectLive(now, deadline: started.addingTimeInterval(75)) // 자리를 쥔 채이므로 120초 안에
                continue
            }
            let temp = AbxSession(name: "ai-" + name.dropFirst(3), socketDir: socketDir, stateDir: stateDir, profileDir: profile.path)
            var env = ["ABX_HEADLESS": "1", "ABX_LOCK_INPUT": "0", "ABX_PROFILE_TEMPLATE": "",
                       "ABX_BROWSERS_DIR": BrowserBinding.browsersDir().path]
            let saved = (try? Data(contentsOf: URL(fileURLWithPath: socketDir).appendingPathComponent("\(name).launch.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let browser = saved?["executablePath"] as? String ?? BrowserBinding.explicitBrowser() { env["ABX_BROWSER"] = browser }
            if let display = BrowserBinding.mainDisplay() { env["ABX_BROWSER_ARGS"] = BrowserBinding.screenInfo(display) }
            var set = 0
            if (try? runner.run(["up", "--headless"], session: temp, extraEnvironment: env, timeout: 40))?.status == 0,
               let url = AbxStateReader().status(temp).cdpUrl.flatMap(URL.init(string:)) {
                set = (try? await ChromeImport.inject(offline, into: url, deadline: started.addingTimeInterval(75)))?.set ?? 0
            }
            // 끈 뒤에야 쿠키가 파일에 다 쓰인다. 임시 세션의 기록은 지운다(다음에 이 화면이 쓸 것이 아님).
            let down = try? runner.run(["down"], session: temp, extraEnvironment: env, timeout: 30)
            if !AbxStateReader().status(temp).running {
                for dir in [socketDir, stateDir] {
                    for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasPrefix(temp.name + ".") {
                        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
                    }
                }
            }
            if set > 0, down?.status == 0 { counts.offline += 1 } else { counts.missed += 1 }
        }
        return counts
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
