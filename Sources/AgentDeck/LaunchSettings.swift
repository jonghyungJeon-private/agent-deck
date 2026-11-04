import AppKit
import BrowserCore
import SwiftUI
import TermLayout
import TermWire

private extension Color {
    init(_ color: NSColor) { self.init(nsColor: color) }
}

enum AgentKind: String {
    case claude, codex
}

/// 새로 띄우는 claude·codex 의 기본 옵션(LaunchOptions)을 들고 `term/launch.json` 에 쓴다.
/// 데이터 위치(DataLocation)를 따라 `TermPaths.home` 을 쓸 때마다 다시 읽으므로 옮기기 뒤에도 새 위치에 쓴다.
final class LaunchSettings: ObservableObject {
    @Published var options: LaunchOptions {
        didSet { if options != oldValue { save() } }
    }

    static var url: URL { TermPaths.home.appendingPathComponent("launch.json") }

    init() {
        options = LaunchOptions.load(from: Self.url)
    }

    func command(_ kind: AgentKind) -> String {
        kind == .claude ? options.claude.command : options.codex.command
    }

    /// 기본 옵션이 위험한지(권한·승인·샌드박스 건너뜀) — 사이드바 + 버튼에 ⚠
    func danger(_ kind: AgentKind) -> String? {
        kind == .claude ? LaunchDanger.claude(options.claude.arguments) : LaunchDanger.codex(options.codex.arguments)
    }

    private func save() {
        guard let data = options.data() else { return }
        try? FileManager.default.createDirectory(at: TermPaths.home, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// 설정 창의 탭(위 도구 막대 아이콘). 이름은 시험 명령 `settings-tab <이름>` 에도 쓴다.
enum SettingsTab: String, CaseIterable {
    /// 연결: Claude Code·Codex hook
    case connections
    /// 브라우저: abx 스킬·전용 브라우저·화면 설정·Chrome 로그인
    case browser
    /// 새 세션: claude·codex 기본 옵션
    case sessions
    /// 화면: 작은 창(🌐·⌨) 버튼 위치
    case screen

    var title: String {
        switch self {
        case .connections: return "연결"
        case .browser: return "브라우저"
        case .sessions: return "새 세션"
        case .screen: return "화면"
        }
    }

    var symbol: String {
        switch self {
        case .connections: return "link"
        case .browser: return "globe"
        case .sessions: return "terminal"
        case .screen: return "macwindow"
        }
    }

    /// 영문 이름·한글 제목 모두 받는다
    init?(name: String) {
        guard let tab = Self.allCases.first(where: { $0.rawValue == name || $0.title == name }) else { return nil }
        self = tab
    }

    static let savedKey = "AgentDeckSettingsTab"
    static var saved: SettingsTab {
        UserDefaults.standard.string(forKey: savedKey).flatMap(SettingsTab.init(name:)) ?? .connections
    }
}

/// 설정 창(앱 메뉴 "설정…" ⌘,). 한 번 만들어 두고 닫아도 다시 쓴다. 위에 탭(도구 막대 아이콘)이 있고,
/// 탭을 바꾸면 창 높이가 그 탭 내용에 맞게 바뀐다. 마지막으로 본 탭을 기억한다.
final class SettingsWindowController {
    private var window: NSWindow?
    private var tabs: SettingsTabViewController?
    private let settings: LaunchSettings
    private let model: TermModel
    private let chromeImport: ChromeImportWindowController

    init(settings: LaunchSettings, model: TermModel, chromeImport: ChromeImportWindowController) {
        self.settings = settings
        self.model = model
        self.chromeImport = chromeImport
    }

    var windowNumber: Int? { window?.windowNumber }
    var selectedTab: SettingsTab? { tabs?.selectedTab }

    /// tab 을 주면 그 탭을 고른다(없으면 마지막에 본 탭)
    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let chromeImport = self.chromeImport
            let tabs = SettingsTabViewController()
            let settings = self.settings, model = self.model, importer = chromeImport.model
            for tab in SettingsTab.allCases {
                tabs.addPage(tab) {
                    switch tab {
                    case .connections:
                        return AnyView(ConnectionsSection(model: model, importer: importer, part: .agents, openChromeImport: { chromeImport.show() }))
                    case .browser:
                        return AnyView(ConnectionsSection(model: model, importer: importer, part: .browser, openChromeImport: { chromeImport.show() }))
                    case .sessions:
                        return AnyView(SessionOptionsSection(settings: settings))
                    case .screen:
                        return AnyView(ScreenSection())
                    }
                }
            }
            tabs.select(SettingsTab.saved)
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .resizable]
            window.toolbarStyle = .preference
            window.backgroundColor = TermAppearance.chrome
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: SettingsTabViewController.width, height: 600))
            window.contentMinSize = NSSize(width: 520, height: 200)
            window.center()
            window.setFrameAutosaveName("AgentDeckSettings")
            self.window = window
            self.tabs = tabs
        }
        if let tab { tabs?.select(tab) }
        // 열 때마다 연결 상태를 다시 본다(다른 곳에서 바꿨을 수 있다)
        model.checkHooks()
        model.checkBrowserSkill()
        tabs?.fit(animated: false)
        if AgentDeckEnv.isOn("NO_ACTIVATE") {
            window?.orderFront(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// 시험용: 창 그림(SwiftUI 글자가 빠지면 `screencapture -l <창 번호>`)
    func snapshot(to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }
}

/// 도구 막대 아이콘 탭. 탭마다 내용(SwiftUI)을 스크롤 칸에 담고, 고르면 창 높이를 그 내용에 맞춘다(화면보다 길면 화면까지, 나머지는 스크롤).
final class SettingsTabViewController: NSTabViewController {
    static let width: CGFloat = 600
    private var pages: [SettingsTab] = []
    private var contents: [SettingsTab: () -> AnyView] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
    }

    func addPage(_ tab: SettingsTab, content: @escaping () -> AnyView) {
        let host = NSHostingController(rootView: SettingsPage(content: content()))
        host.sizingOptions = [] // 창 높이는 아래 fit 이 정한다(내용 크기가 창을 잡지 않게)
        host.title = tab.title // 창 제목 = 고른 탭 이름(없으면 "무제")
        let item = NSTabViewItem(viewController: host)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        pages.append(tab)
        contents[tab] = content
        addTabViewItem(item)
    }

    var selectedTab: SettingsTab? { pages.indices.contains(selectedTabViewItemIndex) ? pages[selectedTabViewItemIndex] : nil }

    func select(_ tab: SettingsTab) {
        guard let index = pages.firstIndex(of: tab), index != selectedTabViewItemIndex else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tab = selectedTab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.savedKey) }
        fit(animated: view.window?.isVisible == true)
    }

    /// 고른 탭의 내용 높이에 창을 맞춘다(위 모서리는 그대로)
    func fit(animated: Bool) {
        guard let window = view.window, let tab = selectedTab, let content = contents[tab] else { return }
        let measure = NSHostingView(rootView: SettingsPage.framed(content()))
        measure.frame = NSRect(x: 0, y: 0, width: Self.width, height: 10)
        var height = ceil(measure.fittingSize.height)
        let maxFrame = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: window.contentRect(forFrameRect: window.frame).width, height: height))
        if frame.height > maxFrame {
            height -= frame.height - maxFrame
            frame.size.height = maxFrame
        }
        var next = window.frame
        guard abs(next.height - frame.height) > 0.5 else { return }
        next.origin.y += next.height - frame.height
        next.size.height = frame.height
        window.setFrame(next, display: true, animate: animated)
    }
}

// MARK: - 화면

/// 탭 한 장: 내용을 스크롤 칸에(길면 스크롤)
private struct SettingsPage: View {
    let content: AnyView
    /// 화면 모드가 바뀌면 내용을 새로 만든다 — AppKit 선택 상자(메뉴 Picker)는 앱 모양이 바뀌어도
    /// 직접 건드린 것만 다시 그려서, 나머지는 이전 모드(예: 다크에서 흰 상자)로 남는다.
    @Environment(\.colorScheme) private var scheme

    /// 스크롤 없이 놓은 모양(높이를 재는 데에도 쓴다)
    static func framed(_ content: AnyView) -> some View {
        content
            .padding(20)
            .frame(width: SettingsTabViewController.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(scheme)
        }
        .background(Color(TermAppearance.chrome))
        .tint(Color(TermAppearance.accent))
    }
}

/// 새 세션: claude·codex 기본 옵션
private struct SessionOptionsSection: View {
    @ObservedObject var settings: LaunchSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("새 세션 기본 옵션")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text("+ claude · + codex · 폴더 메뉴의 \"여기서 … 열기\"로 새로 시작하는 세션에 붙습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            ClaudeCard(launch: $settings.options.claude)
            CodexCard(launch: $settings.options.codex)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                Text("이미 실행 중이거나 되살리는 세션은 처음 실행한 옵션을 그대로 씁니다.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color(TermAppearance.textDim))
            .padding(.horizontal, 4)
        }
    }
}

/// 화면: 작은 창(🌐 브라우저·⌨ 터미널) 버튼과 작은 창의 구석
private struct ScreenSection: View {
    @ObservedObject var corner = FloatCornerSetting.shared
    @ObservedObject var appearance = AppearanceSetting.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("화면")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text("화면 모드와 세션 창 안에 떠 있는 작은 브라우저·작은 터미널. 바꾸면 바로 적용되고, 두 작은 창은 새 구석의 처음 자리로 다시 열립니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            SettingsCard(title: "모양", color: TermAppearance.accent) {
                StatusRow(title: "화면 모드", detail: "자동은 macOS 의 라이트·다크를 따라갑니다. 터미널·편집기·도구 창·설정 창에 모두 바로 적용됩니다.") {
                    ThemedMenu(selection: $appearance.mode, AppearanceMode.allCases.map { ($0, $0.title) })
                }
            }
            SettingsCard(title: "작은 창", color: TermAppearance.accent) {
                StatusRow(title: "작은 창 버튼 위치", detail: "채팅 입력을 가리지 않게 브라우저·터미널 버튼과 작은 창을 둘 곳") {
                    ThemedMenu(selection: $corner.corner, [(.topRight, "오른쪽 위 (기본)"), (.bottomRight, "오른쪽 아래")])
                }
            }
        }
    }
}

// MARK: - 연결·브라우저

/// 연결(Claude Code·Codex hook)과 브라우저(abx 스킬·전용 브라우저·Chrome 로그인) — 사이드바 안내와 같은 동작을 한 곳에서.
/// 두 탭(연결·브라우저)이 같은 도우미를 쓰므로 한 뷰에서 part 로 가른다.
private struct ConnectionsSection: View {
    enum Part { case agents, browser }

    @ObservedObject var model: TermModel
    @ObservedObject var importer: ChromeImportModel
    @ObservedObject var view = BrowserViewSettings.shared
    @ObservedObject var autoOpen = BrowserAutoOpenSetting.shared
    let part: Part
    let openChromeImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(part == .agents ? "연결" : "브라우저")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text(part == .agents ? "Claude Code·Codex 를 이 앱에 잇습니다. 바꾼 것은 새로 시작하는 세션부터 적용됩니다."
                     : "에이전트가 abx 로 쓰는 전용 브라우저입니다. 스킬·설치는 새로 시작하는 세션부터, 화면 설정은 열린 화면에도 바로 적용됩니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            if let notice = model.notice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Color(TermAppearance.textDim))
                .padding(.horizontal, 4)
            }
            if part == .agents {
                SettingsCard(title: "에이전트", color: TermAppearance.accent) {
                    hookRow(title: "Claude Code", detail: "세션 이름·되살리기·작업 상태·알림 (~/.claude/settings.json 의 hook)",
                            state: model.hookState, connect: model.connectHooks, disconnect: model.disconnectHooks)
                    RowDivider()
                    hookRow(title: "Codex", detail: "권한 요청·완료 알림 (~/.codex/hooks.json — 연결 후 Codex /hooks 에서 신뢰)",
                            state: model.codexHookState, connect: model.connectCodexHooks, disconnect: model.disconnectCodexHooks)
                }
            }
            if part == .browser {
                SettingsCard(title: "브라우저", color: TermAppearance.green) {
                    if !model.daemonHasBrowser {
                        WarningLine(text: "세션 데몬이 예전 판이라 화면에 브라우저가 연결되지 않습니다. 모든 세션을 닫고 앱을 끈 뒤 1분쯤 지나 다시 켜세요.")
                    }
                    skillRow
                    RowDivider()
                    chromeRow
                    RowDivider()
                    StatusRow(title: "에이전트가 브라우저를 쓰면 작은 창 자동으로 열기",
                              detail: "에이전트가 abx 를 쓰기 시작하면 그 세션의 작은 브라우저 창을 (키보드를 가져가지 않고) 열고, 결과를 남기지 않고 끝내면 닫습니다. 내가 열었거나 눌러 본 창은 닫지 않고, 작은 창으로 보는 세션에만 적용됩니다") {
                        Toggle("", isOn: $autoOpen.enabled)
                            .labelsHidden()
                            .toggleStyle(TintedSwitch(onColor: TermAppearance.accent))
                    }
                    RowDivider()
                    StatusRow(title: "선명도", detail: "브라우저는 화면 배율(레티나 2배)로 그리고, 화면 칸에는 이 크기까지 받아 보입니다. 열린 화면에도 바로 적용됩니다") {
                        ThemedMenu(selection: $view.options.sharpness, [(.standard, "표준 · 1440까지(가벼움)"),
                                                                        (.sharp, "선명 · 2560까지"),
                                                                        (.max, "최고 · 3840까지(무거움)")])
                    }
                    RowDivider()
                    StatusRow(title: "해상도", detail: "사이트가 보는 화면 크기. 칸에 맞춤은 브라우저 창 크기 그대로(같은 크기의 Chrome 창과 같음), 정하면 그 크기로 그리고 창에 맞게 줄여 보입니다") {
                        ThemedMenu(selection: $view.options.resolution, [(.fit, "칸에 맞춤"), (.r1280x800, "1280 × 800"),
                                                                         (.r1440x900, "1440 × 900"), (.r1920x1080, "1920 × 1080")])
                    }
                    RowDivider()
                    StatusRow(title: "데스크톱 화면 유지", detail: "칸이 좁아도 폭 1024 이상의 데스크톱 화면으로 그리고 줄여 보입니다(끄면 좁은 칸에서 사이트가 모바일 화면으로 바뀔 수 있음)") {
                        Toggle("", isOn: $view.options.keepDesktop)
                            .labelsHidden()
                            .toggleStyle(TintedSwitch(onColor: TermAppearance.accent))
                            .disabled(view.options.resolution != .fit)
                            .opacity(view.options.resolution == .fit ? 1 : 0.4)
                    }
                    RowDivider()
                    StatusRow(title: "쓰지 않으면 쉬게 하기", detail: "AI 가 이만큼 abx 를 쓰지 않고 화면에도 보이지 않으면 브라우저를 꺼서 메모리를 돌려줍니다. 탭은 남겨 두었다가 AI 가 다시 쓰거나 \"다시 켜기\"를 누르면 그대로 열립니다(로그인 유지)") {
                        ThemedMenu(selection: $view.options.idleRest, [(.m15, "15분"), (.m30, "30분"), (.h1, "1시간"),
                                                                       (.h2, "2시간"), (.never, "끄지 않음")])
                    }
                    RowDivider()
                    StatusRow(title: "Chrome 로그인 가져오기",
                              detail: "Chrome 에서 고른 사이트의 로그인(쿠키)을 에이전트 브라우저로 — 비밀번호는 가져오지 않습니다",
                              status: templateStatus) {
                        Button("가져오기…", action: openChromeImport)
                    }
                }
            }
        }
    }

    private func hookRow(title: String, detail: String, state: TermModel.HookState,
                         connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
        let status: (String, NSColor) = {
            switch state {
            case .unknown: return ("확인 중", TermAppearance.textDim)
            case .ok: return ("연결됨", TermAppearance.green)
            case .missing: return ("연결 안 됨", TermAppearance.yellow)
            case .update: return ("갱신 필요", TermAppearance.yellow)
            case .error(let detail): return ("설정을 읽지 못함: \(detail)", TermAppearance.red)
            }
        }()
        return StatusRow(title: title, detail: detail, status: status) {
            switch state {
            case .ok: Button("연결 해제", action: disconnect)
            case .update: Button("갱신하기", action: connect)
            case .missing: Button("연결하기", action: connect)
            default: EmptyView()
            }
        }
    }

    private var skillRow: some View {
        let state = model.browserSkillState
        let status: (String, NSColor) = {
            switch state {
            case .unknown: return ("abx 를 찾지 못함", TermAppearance.textDim)
            case .ok: return ("Claude Code·Codex 에 있음", TermAppearance.green)
            case .missing(let targets): return ("\(targets.joined(separator: "·")) 에 없음", TermAppearance.yellow)
            case .updateFailed(let detail): return ("새 판으로 바꾸지 못함: \(detail)", TermAppearance.red)
            }
        }()
        return StatusRow(title: "abx 스킬", detail: "에이전트가 abx 로 브라우저를 쓰는 법 (~/.claude/skills/abx · ~/.agents/skills/abx)",
                         status: status) {
            switch state {
            case .missing: Button("넣기") { model.connectBrowserSkill(chrome: false) }
            case .updateFailed: Button("다시 시도") { model.checkBrowserSkill() }
            case .ok where model.browserSkillRemovable: Button("연결 해제") { model.disconnectBrowserSkill() }
            default: EmptyView()
            }
        }
    }

    private var chromeRow: some View {
        let state = model.browserChrome
        let version = BrowserInstaller(dir: BrowserBinding.browsersDir()).release.version
        let status: (String, NSColor) = {
            switch state {
            case .unknown: return ("확인 중", TermAppearance.textDim)
            case .ready: return ("받음 (\(version))", TermAppearance.green)
            case .missing: return ("없음 — 그동안 설치된 Chrome 을 씁니다", TermAppearance.yellow)
            case .installing(let percent): return ("받는 중… \(percent)%", TermAppearance.textDim)
            case .failed(let detail): return ("받지 못함: \(detail)", TermAppearance.red)
            }
        }()
        return StatusRow(title: "전용 브라우저", detail: "Chrome for Testing (약 190MB, ~/.abx/browsers) — 평소 쓰는 Chrome 과 따로 돕니다",
                         status: status) {
            switch state {
            case .missing: Button("받기") { model.installBrowserChrome() }
            case .failed: Button("다시 시도") { model.installBrowserChrome() }
            default: EmptyView()
            }
        }
    }

    /// 로그인 템플릿(가져온 로그인)이 있는가 — 가져오기 창이 바뀔 때마다 다시 본다
    private var templateStatus: (String, NSColor) {
        _ = importer.phase
        let template = BrowserBinding.templateDir()
        guard let date = (try? FileManager.default.attributesOfItem(atPath: template.path))?[.modificationDate] as? Date else {
            return ("가져온 로그인 없음", TermAppearance.textDim)
        }
        return ("가져온 로그인 있음 · \(date.formatted(date: .abbreviated, time: .shortened))", TermAppearance.green)
    }
}

/// 이름 + 설명 + 상태(색, 없으면 생략) | 오른쪽 조작
private struct StatusRow<Action: View>: View {
    let title: String
    let detail: String
    var status: (String, NSColor)?
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(TermAppearance.textDim))
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    HStack(spacing: 5) {
                        Circle().fill(Color(status.1)).frame(width: 6, height: 6)
                        Text(status.0).foregroundStyle(Color(status.1)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 7)
    }
}

private struct ClaudeCard: View {
    @Binding var launch: ClaudeLaunch

    var body: some View {
        SettingsCard(title: "Claude Code", color: TermAppearance.claudeColor, canReset: launch != ClaudeLaunch(),
                     reset: { launch = ClaudeLaunch() }) {
            ToggleRow(title: "권한 확인 건너뛰기", flag: "--dangerously-skip-permissions", danger: true, isOn: $launch.skipPermissions)
            if launch.skipPermissions {
                WarningLine(text: "파일 수정·명령 실행을 묻지 않고 바로 합니다. 인터넷이 막힌 샌드박스 같은 곳에서만 쓰세요.")
            }
            RowDivider()
            OptionRow(title: "권한 모드", flag: "--permission-mode",
                      note: launch.skipPermissions ? "권한 확인 건너뛰기가 켜져 있어 쓰지 않습니다" : nil) {
                ChoicePicker(selection: $launch.permissionMode, choices: ClaudeLaunch.permissionModes,
                             labels: ["acceptEdits": "acceptEdits · 편집은 묻지 않음", "plan": "plan · 계획만(고치지 않음)",
                                      "auto": "auto · 자동 판단", "dontAsk": "dontAsk · 허용 목록 밖은 거절",
                                      "bypassPermissions": "bypassPermissions · 모두 허용"])
                    .disabled(launch.skipPermissions)
            }
            if !launch.skipPermissions, launch.permissionMode == "bypassPermissions" {
                WarningLine(text: "bypassPermissions 는 모든 권한 확인을 건너뜁니다(권한 확인 건너뛰기와 같음).")
            }
            RowDivider()
            OptionRow(title: "모델", flag: "--model") {
                ModelField(value: $launch.model, suggestions: ClaudeLaunch.modelSuggestions, placeholder: "기본")
            }
            RowDivider()
            ExtraArgsRow(text: $launch.extraArgs, placeholder: "예: --effort high --add-dir ../shared")
            CommandPreview(program: "claude", arguments: launch.arguments, color: TermAppearance.claudeColor,
                           dangerous: { LaunchDanger.claude([$0]) != nil || $0 == "bypassPermissions" })
        }
    }
}

private struct CodexCard: View {
    @Binding var launch: CodexLaunch

    var body: some View {
        SettingsCard(title: "Codex", color: TermAppearance.codexColor, canReset: launch != CodexLaunch(),
                     reset: { launch = CodexLaunch() }) {
            ToggleRow(title: "승인·샌드박스 건너뛰기 (yolo)", flag: "--dangerously-bypass-approvals-and-sandbox", danger: true,
                      isOn: $launch.bypassApprovalsAndSandbox)
            if launch.bypassApprovalsAndSandbox {
                WarningLine(text: "묻지 않고, 샌드박스 없이 명령을 실행합니다. 바깥에서 따로 격리된 환경에서만 쓰세요.")
            }
            RowDivider()
            let overridden = launch.bypassApprovalsAndSandbox ? "승인·샌드박스 건너뛰기가 켜져 있어 쓰지 않습니다" : nil
            OptionRow(title: "승인 방식", flag: "--ask-for-approval", note: overridden) {
                ChoicePicker(selection: $launch.approval, choices: CodexLaunch.approvals,
                             labels: ["on-request": "on-request · 모델이 필요할 때 물음", "never": "never · 묻지 않음"])
                    .disabled(launch.bypassApprovalsAndSandbox)
            }
            RowDivider()
            OptionRow(title: "샌드박스", flag: "--sandbox", note: overridden) {
                ChoicePicker(selection: $launch.sandbox, choices: CodexLaunch.sandboxes,
                             labels: ["read-only": "read-only · 읽기만", "workspace-write": "workspace-write · 작업 폴더에 쓰기",
                                      "danger-full-access": "danger-full-access · 제한 없음"])
                    .disabled(launch.bypassApprovalsAndSandbox)
            }
            if !launch.bypassApprovalsAndSandbox, launch.sandbox == "danger-full-access" {
                WarningLine(text: "danger-full-access 는 샌드박스 없이 디스크·네트워크 전체에 접근합니다.")
            }
            RowDivider()
            OptionRow(title: "모델", flag: "--model") {
                ModelField(value: $launch.model, suggestions: [], placeholder: "기본 (config.toml)")
            }
            RowDivider()
            ExtraArgsRow(text: $launch.extraArgs, placeholder: "예: --search -c model_reasoning_effort=high")
            CommandPreview(program: "codex", arguments: launch.arguments, color: TermAppearance.codexColor,
                           dangerous: { LaunchDanger.codex([$0]) != nil || $0 == "danger-full-access" })
        }
    }
}

/// 둥근 칸: 머리(색 점 + 이름 + 기본값으로) + 내용
private struct SettingsCard<Content: View>: View {
    let title: String
    let color: NSColor
    var canReset = false
    /// nil 이면 "기본값으로"를 두지 않는다(연결·브라우저 칸)
    var reset: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(color)).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Spacer()
                if let reset {
                    Button("기본값으로", action: reset)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(canReset ? TermAppearance.textDim : TermAppearance.textDim.withAlphaComponent(0.4)))
                        .disabled(!canReset)
                        .help("이 칸의 옵션을 모두 지웁니다")
                }
            }
            .padding(.bottom, 10)
            content
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(TermAppearance.chromeRaised).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(TermAppearance.border), lineWidth: 1))
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color(TermAppearance.border).opacity(0.6)).frame(height: 1).padding(.vertical, 2)
    }
}

/// 이름 + 그 아래 실제 인자(고정폭) | 오른쪽 조작
private struct OptionRow<Control: View>: View {
    let title: String
    let flag: String
    var note: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text(note ?? flag)
                    .font(note == nil ? Font(TermAppearance.uiFont(10.5)) : .system(size: 10.5))
                    .foregroundStyle(Color(note == nil ? TermAppearance.textDim : TermAppearance.yellow))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control.frame(width: 240, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

private struct ToggleRow: View {
    let title: String
    let flag: String
    var danger = false
    @Binding var isOn: Bool

    var body: some View {
        OptionRow(title: title, flag: flag) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(TintedSwitch(onColor: danger ? TermAppearance.red : TermAppearance.accent))
        }
    }
}

/// 켜짐이 창이 앞에 없을 때도 또렷한 스위치(시스템 스위치는 뒤에 있는 창에서 회색으로 바랜다)
private struct TintedSwitch: ToggleStyle {
    let onColor: NSColor

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule()
            .fill(Color(on ? onColor : TermAppearance.border))
            .overlay(Capsule().strokeBorder(Color(on ? onColor : TermAppearance.textDim).opacity(on ? 0 : 0.5), lineWidth: 1))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.12), value: on)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? "켜짐" : "꺼짐")
    }
}

/// 붉은 경고 한 줄(켜진 위험 옵션 바로 아래)
private struct WarningLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(TermAppearance.red))
            Text(text)
                .foregroundStyle(Color(TermAppearance.red).opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(TermAppearance.red).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(TermAppearance.red).opacity(0.45), lineWidth: 1))
        .padding(.bottom, 4)
    }
}

/// "기본"(지정 안 함) + 고를 값들
private struct ChoicePicker: View {
    @Binding var selection: String?
    let choices: [String]
    let labels: [String: String]

    var body: some View {
        var values = choices.map { ($0, labels[$0] ?? $0) }
        // 파일에 이 판이 모르는 값이 있으면 그대로 보인다
        if let selection, !selection.isEmpty, !choices.contains(selection) { values.append((selection, selection)) }
        return ThemedMenu(selection: Binding(get: { selection ?? "" }, set: { selection = $0.isEmpty ? nil : $0 }),
                          sections: [[("", "기본 (지정 안 함)")], values], width: nil)
    }
}

/// 설정 창 선택 상자. 시스템 메뉴 Picker 대신 앱 색(TermAppearance)으로 직접 그린다 —
/// 시스템 상자는 화면 모드를 바꿀 때 조작한 상자만 다시 그리고 강조색(tint)도 조작한 상자에만 들어가서, 상자마다 색이 달랐다.
struct ThemedMenu<Value: Hashable>: View {
    @Binding var selection: Value
    /// 구역마다 (값, 보이는 이름) — 구역 사이에 가름줄
    let sections: [[(Value, String)]]
    /// nil = 자리 폭만큼
    var width: CGFloat? = 200
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    init(selection: Binding<Value>, _ options: [(Value, String)], width: CGFloat? = 200) {
        self.init(selection: selection, sections: [options], width: width)
    }

    init(selection: Binding<Value>, sections: [[(Value, String)]], width: CGFloat? = 200) {
        _selection = selection
        self.sections = sections
        self.width = width
    }

    private var title: String { sections.joined().first { $0.0 == selection }?.1 ?? "" }

    var body: some View {
        Menu {
            ForEach(sections.indices, id: \.self) { section in
                if section > 0 { Divider() }
                ForEach(sections[section].indices, id: \.self) { index in
                    let option = sections[section][index]
                    // 메뉴 안 Toggle = 고른 항목에 체크 표시
                    Toggle(option.1, isOn: Binding(get: { selection == option.0 }, set: { if $0 { selection = option.0 } }))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(TermAppearance.accent))
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(TermAppearance.background)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(hover && enabled ? Color(TermAppearance.accent).opacity(0.7) : Color(TermAppearance.border), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
    }
}

/// 모델: 직접 쓰거나 별칭을 고른다
private struct ModelField: View {
    @Binding var value: String?
    let suggestions: [String]
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .font(Font(TermAppearance.uiFont(12)))
            if !suggestions.isEmpty {
                Menu {
                    Button("기본 (지정 안 함)") { value = nil }
                    Divider()
                    ForEach(suggestions, id: \.self) { name in Button(name) { value = name } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("자주 쓰는 별칭")
            }
        }
    }
}

private struct ExtraArgsRow: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("추가 인자")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Spacer()
                Text("셸처럼 공백으로 나누고, 따옴표로 묶습니다")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Font(TermAppearance.uiFont(12)))
            if ShellWords.split(text).unterminated {
                Text("따옴표가 닫히지 않았습니다 — 끝까지를 한 덩어리로 넘깁니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(TermAppearance.yellow))
            }
        }
        .padding(.vertical, 7)
    }
}

/// 실제로 셸에 넣을 명령(고정폭, 위험한 인자는 붉게). 복사 단추.
private struct CommandPreview: View {
    let program: String
    let arguments: [String]
    let color: NSColor
    let dangerous: (String) -> Bool
    @State private var copied = false

    private var command: String { ShellWords.command([program] + arguments) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            styled
                .font(Font(TermAppearance.uiFont(12)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            .buttonStyle(.plain)
            .help("명령 복사")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(TermAppearance.background)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(TermAppearance.border), lineWidth: 1))
        .padding(.top, 8)
    }

    /// $ claude --flag 값 … (프로그램은 그 색, 옵션은 밝게, 값은 흐리게, 위험한 것은 붉게)
    private var styled: Text {
        var text = Text("$ ").foregroundColor(Color(TermAppearance.textDim))
            + Text(program).foregroundColor(Color(color))
        for arg in arguments {
            let shade: NSColor = dangerous(arg) ? TermAppearance.red
                : arg.hasPrefix("-") ? TermAppearance.textPrimary : TermAppearance.green
            text = text + Text(" " + ShellWords.command([arg])).foregroundColor(Color(shade))
        }
        return text
    }
}
