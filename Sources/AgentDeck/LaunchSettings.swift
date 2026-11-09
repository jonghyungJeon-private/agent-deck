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
            // 배경은 시스템 창 배경(묶음 폼이 그 위에 자기 칸을 그린다) — 앱 팔레트 바탕을 깔지 않는다
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: SettingsTabViewController.width, height: 600))
            window.contentMinSize = NSSize(width: 480, height: 200)
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

/// 도구 막대 아이콘 탭. 탭마다 내용(SwiftUI 묶음 폼)을 담고, 고르면 창 높이를 그 내용에 맞춘다(화면보다 길면 화면까지, 나머지는 폼이 스크롤).
final class SettingsTabViewController: NSTabViewController {
    static let width: CGFloat = 560
    private var pages: [SettingsTab] = []
    private var contents: [SettingsTab: () -> AnyView] = [:]
    private var scaleObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        updateTransition()
        // 글꼴 크기(⌘+ ⌘−)가 바뀌면 글자가 달라져 높이도 달라진다 — 움직임 없이 바로 맞춘다
        scaleObserver = NotificationCenter.default.addObserver(forName: TermAppearance.fontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.fit(animated: false) }
        }
    }

    deinit { scaleObserver.map(NotificationCenter.default.removeObserver) }

    /// 탭 바꿈은 부드럽게 겹쳐 사라지고 나타난다(동작 줄이기면 바로 바뀜)
    private func updateTransition() {
        transitionOptions = Motion.reduced ? [] : [.crossfade, .allowUserInteraction]
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

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, willSelect: tabViewItem)
        updateTransition()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tab = selectedTab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.savedKey) }
        fit(animated: view.window?.isVisible == true)
    }

    /// 고른 탭의 내용 높이에 창을 맞춘다(위 모서리는 그대로). 높이는 창의 지금 폭에서 잰다(폭이 달라지면 줄바꿈도 달라진다).
    func fit(animated: Bool) {
        guard let window = view.window, let tab = selectedTab, let content = contents[tab] else { return }
        let width = window.contentRect(forFrameRect: window.frame).width
        let measure = NSHostingView(rootView: SettingsPage(content: content()).frame(width: width).fixedSize(horizontal: false, vertical: true))
        measure.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        var height = ceil(measure.fittingSize.height)
        let maxFrame = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        if frame.height > maxFrame {
            height -= frame.height - maxFrame
            frame.size.height = maxFrame
        }
        var next = window.frame
        guard abs(next.height - frame.height) > 0.5 else { return }
        next.origin.y += next.height - frame.height
        next.size.height = frame.height
        window.setFrame(next, display: true, animate: animated && !Motion.reduced)
    }
}

// MARK: - 공통 부품

/// 탭 한 장: 묶음 폼(시스템 모양). 글꼴 크기 배율을 안쪽 뷰에 내려 준다(⌘+ ⌘− 를 따라감).
private struct SettingsPage: View {
    let content: AnyView
    @ObservedObject private var scaling = UIScaleModel.shared

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .tint(Color(TermAppearance.accent))
            .environment(\.uiScale, scaling.scale)
    }
}

/// 행의 상태 말: 색은 뜻이다(됨 = 초록, 주의 = 호박, 오류 = 빨강, 안전장치를 약하게 하는 설정 = 난초색 `danger`, 그 밖 = 중립). 색만으로 알리지 않게 기호와 글이 같이 간다.
private struct SettingStatus {
    enum Tone { case ok, warn, bad, danger, neutral }
    let text: String
    let tone: Tone

    var color: NSColor {
        switch tone {
        case .ok: return TermAppearance.statusDone
        case .warn: return TermAppearance.warnText
        case .bad: return TermAppearance.statusAttention
        case .danger: return TermAppearance.dangerText
        case .neutral: return TermAppearance.textSecondary
        }
    }

    var symbol: String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "exclamationmark.octagon.fill"
        case .danger: return "exclamationmark.triangle.fill"
        // 점선 고리는 상태 어휘의 "오케스트레이션"이라 쓰지 않는다
        case .neutral: return "minus.circle"
        }
    }
}

extension AgentKind {
    /// 공용 세션 종류(아이콘·색은 `SessionKind` 가 정한다)
    var sessionKind: SessionKind { self == .claude ? .claude : .codex }
}

/// 구역 머리: 시스템 글꼴(13 굵게). 종류(Claude·Codex)는 아이콘과 종류 색으로.
private struct SectionTitle: View {
    let title: String
    var kind: AgentKind?
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(spacing: Space.xs) {
            if let kind {
                SessionKindIcon(kind: kind.sessionKind, size: ui(TypeSize.emphasis), weight: .semibold).accessibilityHidden(true)
            }
            Text(title).foregroundStyle(Color(TermAppearance.textPrimary))
        }
        .uiTextFont(TypeSize.emphasis, weight: .semibold)
        .textCase(nil)
    }
}

/// 구역 꼬리: 그 구역 전체에 대한 한두 줄 안내(11 보조색)
private struct SectionNote: View {
    @Environment(\.uiScale) private var ui
    let lines: [String]

    init(_ lines: String...) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(lines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, ui(10)) // 시스템 구역 머리의 안쪽 여백에 맞춘다
        .uiTextFont(TypeSize.secondary)
        .foregroundStyle(Color(TermAppearance.textSecondary))
    }
}

/// 오른쪽 조작 칸 폭(선택·입력 상자가 탭마다 같은 오른쪽 끝·같은 폭으로 정렬되게)
private let controlWidth: CGFloat = 220

/// 이름 + 한 줄 설명 + 상태 | 오른쪽 조작. 긴 설명은 `help`(마우스를 올리면)로.
private struct SettingRow<Control: View>: View {
    @Environment(\.uiScale) private var ui
    let title: String
    var detail: String?
    var help: String?
    var status: SettingStatus?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: ui(Space.md)) {
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title)
                    .uiTextFont(TypeSize.emphasis)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                if let detail {
                    Text(detail)
                        .uiTextFont(TypeSize.secondary)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status {
                    HStack(alignment: .firstTextBaseline, spacing: ui(Space.xs)) {
                        Image(systemName: status.symbol).accessibilityHidden(true)
                        Text(status.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .uiTextFont(TypeSize.secondary)
                    .foregroundStyle(Color(status.color))
                }
            }
            Spacer(minLength: ui(Space.sm))
            control
        }
        .help(help ?? "")
    }
}

/// 한 줄 경고(켜진 위험 옵션 바로 아래): 기호 + 글, 위험(`danger`) 색. 색만으로 알리지 않는다.
private struct WarningLine: View {
    @Environment(\.uiScale) private var ui
    let text: String
    var tone: SettingStatus.Tone = .danger

    var body: some View {
        let color = SettingStatus(text: "", tone: tone).color
        HStack(alignment: .firstTextBaseline, spacing: ui(Space.sm)) {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .uiTextFont(TypeSize.secondary)
        .foregroundStyle(Color(color))
    }
}

/// 시스템 메뉴 선택 상자 — 모든 탭에서 같은 폭
private struct SettingPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let sections: [[(Value, String)]]

    init(_ title: String, selection: Binding<Value>, _ options: [(Value, String)]) {
        self.init(title, selection: selection, sections: [options])
    }

    init(_ title: String, selection: Binding<Value>, sections: [[(Value, String)]]) {
        self.title = title
        _selection = selection
        self.sections = sections
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(sections.indices, id: \.self) { section in
                if section > 0 { Divider() }
                ForEach(sections[section].indices, id: \.self) { index in
                    Text(sections[section][index].1).tag(sections[section][index].0)
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: controlWidth, alignment: .trailing)
    }
}

/// 켜고 끄는 시스템 스위치(작게). 위험한 옵션은 켜면 위험(`danger`) 색.
private struct SettingSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var danger = false

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(danger ? Color(TermAppearance.dangerFill) : nil)
    }
}

// MARK: - 새 세션·화면

/// 새 세션: claude·codex 기본 옵션
private struct SessionOptionsSection: View {
    @ObservedObject var settings: LaunchSettings

    var body: some View {
        ClaudeCard(launch: $settings.options.claude)
        CodexCard(launch: $settings.options.codex)
    }
}

/// 화면: 화면 모드와 작은 창(🌐 브라우저·⌨ 터미널) 버튼·구석
private struct ScreenSection: View {
    @ObservedObject var corner = FloatCornerSetting.shared
    @ObservedObject var appearance = AppearanceSetting.shared

    var body: some View {
        Section {
            SettingRow(title: "화면 모드") {
                SettingPicker("화면 모드", selection: $appearance.mode, AppearanceMode.allCases.map { ($0, $0.title) })
            }
        } header: {
            SectionTitle(title: "모양")
        } footer: {
            SectionNote("자동은 macOS 의 라이트·다크를 따라갑니다. 터미널·편집기·도구 창·설정 창에 모두 바로 적용됩니다.")
        }
        Section {
            SettingRow(title: "작은 창 버튼 위치") {
                SettingPicker("작은 창 버튼 위치", selection: $corner.corner, [(.topRight, "오른쪽 위 (기본)"), (.bottomRight, "오른쪽 아래")])
            }
        } header: {
            SectionTitle(title: "작은 창")
        } footer: {
            SectionNote("채팅 입력을 가리지 않게 브라우저·터미널 버튼과 작은 창을 둘 곳입니다.",
                        "바꾸면 바로 적용되고, 두 작은 창은 새 구석의 처음 자리로 다시 열립니다.")
        }
    }
}

// MARK: - 연결·브라우저

/// 연결(Claude Code·Codex hook)과 브라우저(abx 스킬·전용 브라우저·Chrome 로그인) — 사이드바 안내와 같은 동작을 한 곳에서.
/// 두 탭(연결·브라우저)이 같은 도우미를 쓰므로 한 뷰에서 part 로 가른다.
private struct ConnectionsSection: View {
    enum Part { case agents, browser }

    @Environment(\.uiScale) private var ui
    @ObservedObject var model: TermModel
    @ObservedObject var importer: ChromeImportModel
    @ObservedObject var view = BrowserViewSettings.shared
    @ObservedObject var autoOpen = BrowserAutoOpenSetting.shared
    let part: Part
    let openChromeImport: () -> Void

    var body: some View {
        if let notice = model.notice {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: ui(Space.sm)) {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("알림 닫기")
                }
                .uiTextFont(TypeSize.secondary)
                .foregroundStyle(Color(TermAppearance.textSecondary))
            }
        }
        if part == .agents {
            Section {
                hookRow(title: "Claude Code", detail: "세션 이름·되살리기·작업 상태·알림 (~/.claude/settings.json 의 hook)",
                        state: model.hookState, connect: model.connectHooks, disconnect: model.disconnectHooks)
                hookRow(title: "Codex", detail: "권한 요청·완료 알림 (~/.codex/hooks.json — 연결 후 Codex /hooks 에서 신뢰)",
                        state: model.codexHookState, connect: model.connectCodexHooks, disconnect: model.disconnectCodexHooks)
            } header: {
                SectionTitle(title: "에이전트")
            } footer: {
                SectionNote("Claude Code·Codex 를 이 앱에 잇습니다. 바꾼 것은 새로 시작하는 세션부터 적용됩니다.")
            }
        }
        if part == .browser {
            Section {
                if !model.daemonHasBrowser {
                    WarningLine(text: "세션 데몬이 예전 판이라 화면에 브라우저가 연결되지 않습니다. 모든 세션을 닫고 앱을 끈 뒤 1분쯤 지나 다시 켜세요.", tone: .warn)
                }
                skillRow
                chromeRow
            } header: {
                SectionTitle(title: "브라우저")
            } footer: {
                SectionNote("에이전트가 abx 로 쓰는 전용 브라우저입니다. 스킬·설치는 새로 시작하는 세션부터, 화면 설정은 열린 화면에도 바로 적용됩니다.")
            }
            Section {
                SettingRow(title: "에이전트가 브라우저를 쓰면 작은 창 자동으로 열기",
                           detail: "에이전트가 abx 를 쓰기 시작하면 그 세션의 작은 브라우저 창을 열고, 결과를 남기지 않고 끝내면 닫습니다.",
                           help: "키보드를 가져가지 않고 엽니다. 내가 열었거나 눌러 본 창은 닫지 않고, 작은 창으로 보는 세션에만 적용됩니다.") {
                    SettingSwitch(title: "에이전트가 브라우저를 쓰면 작은 창 자동으로 열기", isOn: $autoOpen.enabled)
                }
                SettingRow(title: "선명도", detail: "화면 칸에 받아 보이는 최대 크기입니다. 열린 화면에도 바로 적용됩니다.",
                           help: "브라우저는 화면 배율(레티나 2배)로 그리고, 화면 칸에는 이 크기까지 받아 보입니다.") {
                    SettingPicker("선명도", selection: $view.options.sharpness, [(.standard, "표준 · 1440까지(가벼움)"),
                                                                                 (.sharp, "선명 · 2560까지"),
                                                                                 (.max, "최고 · 3840까지(무거움)")])
                }
                SettingRow(title: "해상도", detail: "사이트가 보는 화면 크기입니다. 칸에 맞춤은 브라우저 창 크기 그대로입니다.",
                           help: "칸에 맞춤은 브라우저 창 크기 그대로(같은 크기의 Chrome 창과 같음), 정하면 그 크기로 그리고 창에 맞게 줄여 보입니다.") {
                    SettingPicker("해상도", selection: $view.options.resolution, [(.fit, "칸에 맞춤"), (.r1280x800, "1280 × 800"),
                                                                                  (.r1440x900, "1440 × 900"), (.r1920x1080, "1920 × 1080")])
                }
                SettingRow(title: "데스크톱 화면 유지", detail: "칸이 좁아도 폭 1024 이상의 데스크톱 화면으로 그리고 줄여 보입니다.",
                           help: "끄면 좁은 칸에서 사이트가 모바일 화면으로 바뀔 수 있습니다. 해상도가 \"칸에 맞춤\"일 때만 쓰입니다.") {
                    SettingSwitch(title: "데스크톱 화면 유지", isOn: $view.options.keepDesktop)
                        .disabled(view.options.resolution != .fit)
                }
                SettingRow(title: "쓰지 않으면 쉬게 하기", detail: "AI 가 이만큼 abx 를 쓰지 않고 화면에도 보이지 않으면 브라우저를 꺼서 메모리를 돌려줍니다.",
                           help: "탭은 남겨 두었다가 AI 가 다시 쓰거나 \"다시 켜기\"를 누르면 그대로 열립니다(로그인 유지).") {
                    SettingPicker("쓰지 않으면 쉬게 하기", selection: $view.options.idleRest, [(.m15, "15분"), (.m30, "30분"), (.h1, "1시간"),
                                                                                              (.h2, "2시간"), (.never, "끄지 않음")])
                }
            } header: {
                SectionTitle(title: "화면 설정")
            }
            Section {
                SettingRow(title: "Chrome 로그인 가져오기",
                           detail: "Chrome 에서 고른 사이트의 로그인(쿠키)을 에이전트 브라우저로 — 비밀번호는 가져오지 않습니다",
                           status: templateStatus) {
                    Button("가져오기…", action: openChromeImport)
                }
            } header: {
                SectionTitle(title: "Chrome")
            }
        }
    }

    private func hookRow(title: String, detail: String, state: TermModel.HookState,
                         connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
        let status: SettingStatus = {
            switch state {
            case .unknown: return SettingStatus(text: "확인 중", tone: .neutral)
            case .ok: return SettingStatus(text: "연결됨", tone: .ok)
            case .missing: return SettingStatus(text: "연결 안 됨", tone: .warn)
            case .update: return SettingStatus(text: "갱신 필요", tone: .warn)
            case .error(let detail): return SettingStatus(text: "설정을 읽지 못함: \(detail)", tone: .bad)
            }
        }()
        return SettingRow(title: title, detail: detail, status: status) {
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
        let status: SettingStatus = {
            switch state {
            case .unknown: return SettingStatus(text: "abx 를 찾지 못함", tone: .neutral)
            case .ok: return SettingStatus(text: "Claude Code·Codex 에 있음", tone: .ok)
            case .missing(let targets): return SettingStatus(text: "\(targets.joined(separator: "·")) 에 없음", tone: .warn)
            case .updateFailed(let detail): return SettingStatus(text: "새 판으로 바꾸지 못함: \(detail)", tone: .bad)
            }
        }()
        return SettingRow(title: "abx 스킬", detail: "에이전트가 abx 로 브라우저를 쓰는 법 (~/.claude/skills/abx · ~/.agents/skills/abx)",
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
        let status: SettingStatus = {
            switch state {
            case .unknown: return SettingStatus(text: "확인 중", tone: .neutral)
            case .ready: return SettingStatus(text: "받음 (\(version))", tone: .ok)
            case .missing: return SettingStatus(text: "없음 — 그동안 설치된 Chrome 을 씁니다", tone: .warn)
            case .installing(let percent): return SettingStatus(text: "받는 중… \(percent)%", tone: .neutral)
            case .failed(let detail): return SettingStatus(text: "받지 못함: \(detail)", tone: .bad)
            }
        }()
        return SettingRow(title: "전용 브라우저", detail: "Chrome for Testing (약 190MB, ~/.abx/browsers) — 평소 쓰는 Chrome 과 따로 돕니다",
                          status: status) {
            switch state {
            case .missing: Button("받기") { model.installBrowserChrome() }
            case .failed: Button("다시 시도") { model.installBrowserChrome() }
            default: EmptyView()
            }
        }
    }

    /// 로그인 템플릿(가져온 로그인)이 있는가 — 가져오기 창이 바뀔 때마다 다시 본다
    private var templateStatus: SettingStatus {
        _ = importer.phase
        let template = BrowserBinding.templateDir()
        guard let date = (try? FileManager.default.attributesOfItem(atPath: template.path))?[.modificationDate] as? Date else {
            return SettingStatus(text: "가져온 로그인 없음", tone: .neutral)
        }
        return SettingStatus(text: "가져온 로그인 있음 · \(date.formatted(date: .abbreviated, time: .shortened))", tone: .ok)
    }
}

// MARK: - claude·codex 옵션

private struct ClaudeCard: View {
    @Binding var launch: ClaudeLaunch

    var body: some View {
        Section {
            ToggleRow(title: "권한 확인 건너뛰기", flag: "--dangerously-skip-permissions", danger: true, isOn: $launch.skipPermissions)
            if launch.skipPermissions {
                WarningLine(text: "파일 수정·명령 실행을 묻지 않고 바로 합니다. 인터넷이 막힌 샌드박스 같은 곳에서만 쓰세요.")
            }
            OptionRow(title: "권한 모드", flag: "--permission-mode",
                      note: launch.skipPermissions ? "권한 확인 건너뛰기가 켜져 있어 쓰지 않습니다" : nil) {
                ChoicePicker(title: "권한 모드", selection: $launch.permissionMode, choices: ClaudeLaunch.permissionModes,
                             labels: ["acceptEdits": "acceptEdits · 편집은 묻지 않음", "plan": "plan · 계획만(고치지 않음)",
                                      "auto": "auto · 자동 판단", "dontAsk": "dontAsk · 허용 목록 밖은 거절",
                                      "bypassPermissions": "bypassPermissions · 모두 허용"])
                    .disabled(launch.skipPermissions)
            }
            if !launch.skipPermissions, launch.permissionMode == "bypassPermissions" {
                WarningLine(text: "bypassPermissions 는 모든 권한 확인을 건너뜁니다(권한 확인 건너뛰기와 같음).")
            }
            OptionRow(title: "모델", flag: "--model") {
                ModelField(title: "모델", value: $launch.model, suggestions: ClaudeLaunch.modelSuggestions, placeholder: "기본")
            }
            ExtraArgsRow(text: $launch.extraArgs, placeholder: "예: --effort high --add-dir ../shared")
            CommandPreview(program: "claude", arguments: launch.arguments, color: TermAppearance.typeClaude,
                           dangerous: { LaunchDanger.claude([$0]) != nil || $0 == "bypassPermissions" })
        } header: {
            HStack {
                SectionTitle(title: "Claude Code", kind: .claude)
                Spacer()
                ResetButton(canReset: launch != ClaudeLaunch(), reset: { launch = ClaudeLaunch() })
            }
        } footer: {
            SectionNote("+ claude · 폴더 메뉴의 \"여기서 … 열기\"로 새로 시작하는 세션에 붙습니다.")
        }
    }
}

private struct CodexCard: View {
    @Binding var launch: CodexLaunch

    var body: some View {
        Section {
            ToggleRow(title: "승인·샌드박스 건너뛰기 (yolo)", flag: "--dangerously-bypass-approvals-and-sandbox", danger: true,
                      isOn: $launch.bypassApprovalsAndSandbox)
            if launch.bypassApprovalsAndSandbox {
                WarningLine(text: "묻지 않고, 샌드박스 없이 명령을 실행합니다. 바깥에서 따로 격리된 환경에서만 쓰세요.")
            }
            let overridden = launch.bypassApprovalsAndSandbox ? "승인·샌드박스 건너뛰기가 켜져 있어 쓰지 않습니다" : nil
            OptionRow(title: "승인 방식", flag: "--ask-for-approval", note: overridden) {
                ChoicePicker(title: "승인 방식", selection: $launch.approval, choices: CodexLaunch.approvals,
                             labels: ["on-request": "on-request · 모델이 필요할 때 물음", "never": "never · 묻지 않음"])
                    .disabled(launch.bypassApprovalsAndSandbox)
            }
            OptionRow(title: "샌드박스", flag: "--sandbox", note: overridden) {
                ChoicePicker(title: "샌드박스", selection: $launch.sandbox, choices: CodexLaunch.sandboxes,
                             labels: ["read-only": "read-only · 읽기만", "workspace-write": "workspace-write · 작업 폴더에 쓰기",
                                      "danger-full-access": "danger-full-access · 제한 없음"])
                    .disabled(launch.bypassApprovalsAndSandbox)
            }
            if !launch.bypassApprovalsAndSandbox, launch.sandbox == "danger-full-access" {
                WarningLine(text: "danger-full-access 는 샌드박스 없이 디스크·네트워크 전체에 접근합니다.")
            }
            OptionRow(title: "모델", flag: "--model") {
                ModelField(title: "모델", value: $launch.model, suggestions: [], placeholder: "기본 (config.toml)")
            }
            ExtraArgsRow(text: $launch.extraArgs, placeholder: "예: --search -c model_reasoning_effort=high")
            CommandPreview(program: "codex", arguments: launch.arguments, color: TermAppearance.typeCodex,
                           dangerous: { LaunchDanger.codex([$0]) != nil || $0 == "danger-full-access" })
        } header: {
            HStack {
                SectionTitle(title: "Codex", kind: .codex)
                Spacer()
                ResetButton(canReset: launch != CodexLaunch(), reset: { launch = CodexLaunch() })
            }
        } footer: {
            SectionNote("+ codex · 폴더 메뉴의 \"여기서 … 열기\"로 새로 시작하는 세션에 붙습니다.",
                        "이미 실행 중이거나 되살리는 세션은 처음 실행한 옵션을 그대로 씁니다.")
        }
    }
}

/// 구역 머리 오른쪽 "기본값으로": 지울 것이 없으면 꺼진다(시스템이 바랜다)
private struct ResetButton: View {
    let canReset: Bool
    let reset: () -> Void

    var body: some View {
        Button("기본값으로", action: reset)
            .controlSize(.small)
            .disabled(!canReset)
            .help("이 칸의 옵션을 모두 지웁니다")
    }
}

/// 이름 + 그 아래 실제 인자(고정폭, 한 줄·가운데 줄임) | 오른쪽 조작
private struct OptionRow<Control: View>: View {
    @Environment(\.uiScale) private var ui
    let title: String
    let flag: String
    var note: String?
    /// nil = 조작이 제 크기대로(스위치)
    var width: CGFloat? = controlWidth
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: ui(Space.md)) {
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title)
                    .uiTextFont(TypeSize.emphasis)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                if let note {
                    Text(note)
                        .uiTextFont(TypeSize.secondary)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(flag)
                        .uiFont(TypeSize.secondary)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(flag)
                }
            }
            Spacer(minLength: ui(Space.sm))
            control.frame(width: width, alignment: .trailing)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let flag: String
    var danger = false
    @Binding var isOn: Bool

    var body: some View {
        OptionRow(title: title, flag: flag, width: nil) {
            SettingSwitch(title: title, isOn: $isOn, danger: danger)
        }
    }
}

/// "기본"(지정 안 함) + 고를 값들
private struct ChoicePicker: View {
    let title: String
    @Binding var selection: String?
    let choices: [String]
    let labels: [String: String]

    var body: some View {
        var values = choices.map { ($0, labels[$0] ?? $0) }
        // 파일에 이 판이 모르는 값이 있으면 그대로 보인다
        if let selection, !selection.isEmpty, !choices.contains(selection) { values.append((selection, selection)) }
        return SettingPicker(title, selection: Binding(get: { selection ?? "" }, set: { selection = $0.isEmpty ? nil : $0 }),
                             sections: [[("", "기본 (지정 안 함)")], values])
    }
}

/// 모델: 직접 쓰거나 별칭을 고른다(같은 칸 폭 안에서)
private struct ModelField: View {
    @Environment(\.uiScale) private var ui
    let title: String
    @Binding var value: String?
    let suggestions: [String]
    let placeholder: String

    var body: some View {
        HStack(spacing: ui(Space.xs)) {
            TextField(title, text: Binding(get: { value ?? "" }, set: { value = $0.isEmpty ? nil : $0 }),
                      prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .uiFont(TypeSize.row)
            if !suggestions.isEmpty {
                Menu {
                    Button("기본 (지정 안 함)") { value = nil }
                    Divider()
                    ForEach(suggestions, id: \.self) { name in Button(name) { value = name } }
                } label: {
                    Image(systemName: "chevron.down").foregroundStyle(Color(TermAppearance.textSecondary))
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
    @Environment(\.uiScale) private var ui
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: ui(Space.xs)) {
            Text("추가 인자")
                .uiTextFont(TypeSize.emphasis)
                .foregroundStyle(Color(TermAppearance.textPrimary))
            Text("셸처럼 공백으로 나누고, 따옴표로 묶습니다")
                .uiTextFont(TypeSize.secondary)
                .foregroundStyle(Color(TermAppearance.textSecondary))
            TextField("추가 인자", text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .uiFont(TypeSize.row)
            if ShellWords.split(text).unterminated {
                WarningLine(text: "따옴표가 닫히지 않았습니다 — 끝까지를 한 덩어리로 넘깁니다.", tone: .warn)
            }
        }
    }
}

/// 실제로 셸에 넣을 명령(고정폭, 위험한 인자는 붉게). 복사 단추.
private struct CommandPreview: View {
    @Environment(\.uiScale) private var ui
    let program: String
    let arguments: [String]
    let color: NSColor
    let dangerous: (String) -> Bool
    @State private var copied = false

    private var command: String { ShellWords.command([program] + arguments) }

    var body: some View {
        HStack(alignment: .top, spacing: ui(Space.sm)) {
            styled
                .uiFont(TypeSize.row)
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
                    .foregroundStyle(Color(TermAppearance.textSecondary))
            }
            .buttonStyle(.borderless)
            .help("명령 복사")
            .accessibilityLabel("명령 복사")
        }
        .padding(.horizontal, ui(Space.md))
        .padding(.vertical, ui(Space.sm))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(TermAppearance.background)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(TermAppearance.border), lineWidth: 1))
    }

    /// $ claude --flag 값 … (프로그램은 종류 색, 옵션은 밝게, 값은 보조색, 위험한 것은 위험 색)
    private var styled: Text {
        var text = Text("$ ").foregroundColor(Color(TermAppearance.textSecondary))
            + Text(program).foregroundColor(Color(color))
        for arg in arguments {
            let shade: NSColor = dangerous(arg) ? TermAppearance.dangerText
                : arg.hasPrefix("-") ? TermAppearance.textPrimary : TermAppearance.textSecondary
            text = text + Text(" " + ShellWords.command([arg])).foregroundColor(Color(shade))
        }
        return text
    }
}
