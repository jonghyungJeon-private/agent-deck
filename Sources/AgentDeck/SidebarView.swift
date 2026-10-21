import AppKit
import SwiftUI
import TermLayout
import TermWire

private extension Color {
    init(_ color: NSColor) { self.init(nsColor: color) }
}

/// 왼쪽 목록(herdr 처럼): 폴더(git 저장소)별 묶음 → 작업 트리(worktree) → 그 안의 세션.
/// 어두운 바탕에 고정폭 글꼴, 색은 상태와 포커스에만 쓴다.
struct SidebarView: View {
    @ObservedObject var model: TermModel
    /// 접기·순서(term/spaces.json). 목록에 보이는 방식일 뿐 탭 순서와는 상관없다.
    @ObservedObject private var spaces: SpacesStore
    /// 새 세션 기본 옵션(+ 버튼의 ⚠·풍선 도움말)
    @ObservedObject private var launch: LaunchSettings
    /// 도크에 도구가 하나뿐이면 머리 줄에 "spaces" 를 보인다(둘이면 위 도구 버튼 줄이 보인다)
    var showsTitle = true
    /// 머리 줄 오른쪽 클릭: 왼쪽·오른쪽으로 옮기기, 숨기기
    var onDock: ((DockSide) -> Void)?
    var currentSide: DockSide = .left
    /// 펼쳐 본 하위 에이전트(마지막 메시지를 보여 준다)
    @State private var expandedAgent: String?
    /// 글꼴 크기 배율(⌘+ ⌘−) — 안쪽 뷰에는 `\.uiScale` 로 내려 준다
    @ObservedObject private var scaling = UIScaleModel.shared
    private var ui: UIScale { scaling.scale }

    init(model: TermModel, showsTitle: Bool = true, onDock: ((DockSide) -> Void)? = nil, currentSide: DockSide = .left) {
        _model = ObservedObject(wrappedValue: model)
        _spaces = ObservedObject(wrappedValue: model.spaces)
        _launch = ObservedObject(wrappedValue: model.launch)
        self.showsTitle = showsTitle
        self.onDock = onDock
        self.currentSide = currentSide
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.groups.isEmpty {
                        Text(model.connectionStatusText ?? "열린 세션이 없습니다.\n위 + 버튼으로 시작하세요.")
                            .uiFont(11)
                            .foregroundStyle(Color(TermAppearance.textDim))
                            .padding(ui(14))
                    }
                    // 묶음·작업 트리·세션을 한 줄짜리 목록으로 펼쳐 그린다.
                    // ForEach 를 겹쳐 쓰면 안쪽 줄이 바뀐 것을 SwiftUI 가 놓쳐 이름이 늦게 바뀌었다.
                    let items = SidebarItem.flatten(model.groups, spaces: spaces.state)
                    ForEach(items) { item in
                        row(item)
                            .opacity(isDragged(item) ? 0.35 : 1)
                            .overlay(alignment: insertion(item) == .below ? .bottom : .top) {
                                if let edge = insertion(item) { InsertionLine(edge: edge, indent: ui(item.indent)) }
                            }
                            .onDrop(of: [.text], delegate: SpacesDropDelegate(item: item, items: items,
                                                                              groups: model.groups, store: spaces))
                            .onHover { inside in
                                // 창 밖에 놓는 등 끌기가 취소되면 놓기 알림이 없다 → 마우스가 떼진 채 다시 오면 지운다
                                if inside, spaces.drag != nil, NSEvent.pressedMouseButtons == 0 { spaces.drag = nil }
                            }
                    }
                }
                .padding(.vertical, ui(4))
            }
            hookBanner
            codexHookBanner
        }
        .frame(minWidth: 220, maxHeight: .infinity)
        .background(Color(TermAppearance.chrome))
        .environment(\.colorScheme, .dark)
        .environment(\.uiScale, ui)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        switch item {
        case .group(let group, let collapsed, let summary):
            GroupRowView(group: group, collapsed: collapsed, summary: summary,
                         holdsSelection: collapsed && group.sections.contains { $0.rows.contains { $0.id == model.selectedId } },
                         onToggle: { spaces.toggle(SpacesState.groupKey(group.path)) },
                         menu: { openMenu(group.path) },
                         context: {
                             Button(collapsed ? "펼치기" : "접기") { spaces.toggle(SpacesState.groupKey(group.path)) }
                             collapseAllButtons
                             Divider()
                             openMenu(group.path)
                         })
                .onDrag {
                    spaces.drag = SpacesDrag(kind: .group, id: group.path)
                    return NSItemProvider(object: group.path as NSString)
                }
        case .worktree(let section, _, let collapsed, let summary):
            WorktreeRowView(section: section, collapsed: collapsed, summary: summary,
                            holdsSelection: collapsed && section.rows.contains { $0.id == model.selectedId },
                            onToggle: { spaces.toggle(SpacesState.worktreeKey(section.path)) })
                .contextMenu {
                    Button(collapsed ? "펼치기" : "접기") { spaces.toggle(SpacesState.worktreeKey(section.path)) }
                    Divider()
                    openMenu(section.path)
                }
        case .session(let row, let depth, _, let section):
            SessionRowView(row: row, depth: depth,
                           selected: row.id == model.selectedId,
                           tabNumber: model.workspace.tabIndex(containing: row.id).map { $0 + 1 })
                .onTapGesture { model.focus(pane: row.id) }
                .onDrag {
                    spaces.drag = SpacesDrag(kind: .session, id: row.id, section: section)
                    return NSItemProvider(object: row.id as NSString)
                }
                .contextMenu {
                    Button("이름 바꾸기…") { model.rename(pane: row.id) }
                    Button("화면 닫기(셸·에이전트 종료)") { model.close(pane: row.id) }
                    Divider()
                    openMenu(row.cwd)
                }
        case .agent(let agent, let depth, let owner, _):
            AgentRowView(agent: agent, depth: depth, owner: owner, expanded: expandedAgent == agent.id)
                .onTapGesture {
                    // 띄운 에이전트 화면으로 넘어가고, 무엇을 하는지 펼쳐 본다
                    model.focus(pane: agent.paneId)
                    expandedAgent = expandedAgent == agent.id ? nil : agent.id
                }
        case .gap:
            // 묶음 끝 틈: 묶음을 끌어 내릴 때 놓을 자리 줄이 여기 그려진다
            Color.clear.frame(height: ui(10)).contentShape(Rectangle())
        }
    }

    private func isDragged(_ item: SidebarItem) -> Bool {
        guard let drag = spaces.drag else { return false }
        switch (drag.kind, item) {
        case (.group, .gap): return false
        case (.group, _): return item.groupPath == drag.id
        case (.session, .session(let row, _, _, _)): return row.id == drag.id
        default: return false
        }
    }

    /// 끌어 놓을 자리 표시: 묶음은 머리 줄 위(올릴 때) 또는 묶음 끝 틈(내릴 때), 세션은 그 줄 위·아래
    private func insertion(_ item: SidebarItem) -> InsertionLine.Edge? {
        guard let drag = spaces.drag, let target = drag.target else { return nil }
        switch (drag.kind, item) {
        case (.group, .group(let group, _, _)) where group.path == target && !drag.after: return .above
        case (.group, .gap(let path)) where path == target && drag.after: return .middle
        case (.session, .session(let row, _, _, _)) where row.id == target: return drag.after ? .below : .above
        default: return nil
        }
    }

    @ViewBuilder
    private var collapseAllButtons: some View {
        Button("모두 접기") { spaces.collapseAll(model.groups) }
        Button("모두 펼치기") { spaces.expandAll() }
    }

    /// 지금 펼쳐진 묶음·작업 트리가 하나라도 있는지(머리 줄 버튼이 접기/펼치기 중 무엇을 할지)
    private var anyExpanded: Bool {
        SpacesStore.collapsibleKeys(model.groups).contains { !spaces.state.isCollapsed($0) }
    }

    private var header: some View {
        HStack(spacing: ui(4)) {
            if showsTitle {
                Text("spaces")
                    .uiFont(11)
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            Spacer()
            if !model.groups.isEmpty {
                let collapse = anyExpanded
                IconChromeButton(symbol: collapse ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                                 help: collapse ? "모두 접기" : "모두 펼치기") {
                    if collapse { spaces.collapseAll(model.groups) } else { spaces.expandAll() }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ui(4)) {
                    agentButton(.claude)
                    agentButton(.codex)
                    ChromeButton(label: "+ 셸", help: "홈 폴더에서 새 셸 탭 (지금 화면 폴더는 ⌘T)") {
                        model.newPane(cwd: NSHomeDirectory())
                    }
                }
                .fixedSize()
                Menu("+ 새 세션") { newSessionItems }
                    .fixedSize()
            }
        }
        .padding(.leading, ui(14))
        .padding(.trailing, ui(8))
        .frame(height: TerminalHostController.tabBarHeight)
        .contentShape(Rectangle())
        .contextMenu {
            collapseAllButtons
            if let onDock {
                Divider()
                Button((currentSide == .left ? "✓ " : "") + "왼쪽으로 옮기기") { onDock(.left) }
                Button((currentSide == .right ? "✓ " : "") + "오른쪽으로 옮기기") { onDock(.right) }
                Divider()
                Button("숨기기 (⌘⇧S)") { onDock(.hidden) }
            }
        }
    }

    @ViewBuilder
    private var newSessionItems: some View {
        Button("Claude Code…") { pickFolder(.claude) { model.newAgent(.claude, cwd: $0) } }
        Button("Codex…") { pickFolder(.codex) { model.newAgent(.codex, cwd: $0) } }
        Button("셸") { model.newPane(cwd: NSHomeDirectory()) }
    }

    /// hook 이 없거나 예전 앱 것이면 눈에 띄게 알린다(이름·되살리기·상태 표시가 여기에 달려 있다)
    @ViewBuilder
    private var hookBanner: some View {
        let message: String? = {
            switch model.hookState {
            case .missing: return "Claude Code 와 연결되지 않았습니다. 세션 이름·되살리기·상태 표시에 필요합니다."
            case .update: return "Claude Code 연결이 예전 판(예전 이름 ClaudeTerm·ClaudeSessions 포함)이거나 다른 위치(옮기기 전 앱)를 가리킵니다. 갱신하면 이 앱으로 바로잡고, 앱을 지우거나 옮겨도 오류가 나지 않는 형태로 바꿉니다."
            case .error(let detail): return "Claude Code 설정을 읽지 못했습니다: \(detail)"
            default: return nil
            }
        }()
        let canConnect: Bool = {
            if case .error = model.hookState { return false }
            return true
        }()
        if let message {
            VStack(alignment: .leading, spacing: ui(6)) {
                Text(message)
                    .uiFont(11)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                if canConnect {
                    Button {
                        model.connectHooks()
                    } label: {
                        Text(model.hookState == .update ? "갱신하기" : "연결하기")
                            .uiFont(11, bold: true)
                            .foregroundStyle(Color(TermAppearance.chrome))
                            .padding(.horizontal, ui(10))
                            .padding(.vertical, ui(4))
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(TermAppearance.accent)))
                    }
                    .buttonStyle(.plain)
                    .help("~/.claude/settings.json 에 세션 기록·작업 상태 hook 을 넣습니다(바꾸기 전 백업, 다른 hook 은 그대로). 앱을 지우면 hook 은 아무것도 하지 않습니다.")
                }
            }
            .padding(ui(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(TermAppearance.accent), lineWidth: 1))
            .padding(.horizontal, ui(10))
            .padding(.bottom, ui(8))
        }
        if let notice = model.notice {
            Text(notice)
                .uiFont(10)
                .foregroundStyle(Color(TermAppearance.textDim))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ui(14))
                .padding(.bottom, ui(6))
                .onTapGesture { model.notice = nil }
        }
    }

    @ViewBuilder
    private var codexHookBanner: some View {
        if model.codexHookState != .unknown && model.codexHookState != .ok {
            VStack(alignment: .leading, spacing: ui(6)) {
                Text(model.codexHookState == .update
                     ? "Codex 연결이 예전 판이거나 다른 위치의 앱을 가리킵니다. 갱신한 뒤 Codex의 /hooks 에서 훅을 다시 신뢰하세요."
                     : "Codex의 권한 요청·완료 알림을 연결할 수 있습니다. 연결 후 Codex의 /hooks 에서 훅을 검토·신뢰하세요.")
                    .fixedSize(horizontal: false, vertical: true)
                if case .error(let detail) = model.codexHookState {
                    Text(detail).foregroundStyle(Color(TermAppearance.red))
                } else {
                    Button(model.codexHookState == .update ? "Codex 연결 갱신" : "Codex 연결하기") { model.connectCodexHooks() }
                }
            }
            .uiFont(10)
            .foregroundStyle(Color(TermAppearance.textDim))
            .padding(.horizontal, ui(14))
            .padding(.bottom, ui(8))
        }
    }

    /// 폴더·작업 트리에서 새로 열기
    @ViewBuilder
    private func openMenu(_ path: String) -> some View {
        Button("여기서 claude 열기(새 탭)") { model.newAgent(.claude, cwd: path) }
        Button("여기서 codex 열기(새 탭)") { model.newAgent(.codex, cwd: path) }
        Button("여기서 셸 열기(새 탭)") { model.newPane(cwd: path) }
        Button("Finder 에서 보기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    }

    /// + claude·+ codex: 기본 옵션이 위험하면 ⚠ 를 붙이고, 풍선 도움말에 실제 명령을 보인다
    private func agentButton(_ kind: AgentKind) -> some View {
        let warning = launch.danger(kind)
        return ChromeButton(label: "+ \(kind.rawValue)" + (warning == nil ? "" : " ⚠"),
                            help: "폴더를 골라 새 탭에서 실행: \(launch.command(kind))"
                                + (warning.map { "\n⚠ \($0)" } ?? "") + "\n기본 옵션은 설정(⌘,)에서 바꿉니다") {
            pickFolder(kind) { model.newAgent(kind, cwd: $0) }
        }
    }

    private func pickFolder(_ kind: AgentKind, _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "여기서 \(kind.rawValue) 실행"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(url.path)
    }
}

/// 사이드바 위 글자 버튼
struct ChromeButton: View {
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            Text(label)
                .uiFont(11)
                .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textDim))
                .padding(.horizontal, ui(7))
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(hovering ? TermAppearance.chromeRaised : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 사이드바 위 그림 버튼(글자 버튼과 같은 모양)
struct IconChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ui(11), weight: .medium))
                .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textDim))
                .frame(width: ui(22), height: ui(20))
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(hovering ? TermAppearance.chromeRaised : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 상태 점. 꺼진 화면·쉬는 중은 속이 빈 점, 입력 대기는 테두리를 두른 점, 오케스트레이션 중은 점선 고리 + 가운데 점
/// (색만으로 구분하지 않게 모양도 다르게).
struct StatusDot: View {
    let status: WorkStatus
    var dormant = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        let color = Color(dormant ? TermAppearance.textDim.withAlphaComponent(0.8) : status.color)
        let hollow = dormant || status == .idle
        Group {
            if hollow {
                Circle().strokeBorder(color, lineWidth: 1.2)
            } else if case .waiting = status {
                Circle().fill(color).padding(2).overlay(Circle().strokeBorder(color, lineWidth: 1))
            } else if case .orchestrating = status {
                // 오케스트레이션 중: 점선 고리(돌고 있는 일들) + 가운데 작은 점(메인)
                Circle().fill(color).padding(ui(2.6))
                    .overlay(Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [1.8, 1.3])))
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: ui(8), height: ui(8))
    }
}

/// 접기 화살표(▸ 접힘, ▾ 펼침)
struct DisclosureChevron: View {
    let collapsed: Bool
    var highlighted = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: ui(8), weight: .bold))
            .foregroundStyle(Color(highlighted ? TermAppearance.textPrimary : TermAppearance.textDim))
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .frame(width: ui(10), height: ui(10))
    }
}

/// 접힌 줄의 상태 합계: 상태 점 + 수(입력 대기·오류는 붉은 바탕으로 눈에 띄게), 일하는 하위 에이전트, 세션 수
struct SpacesSummaryView: View {
    let summary: SpacesSummary
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(spacing: ui(6)) {
            ForEach(SpacesSummary.Kind.allCases.filter { summary.count($0) > 0 }, id: \.self) { kind in
                let attention = kind == .waiting || kind == .error
                HStack(spacing: ui(3)) {
                    StatusDot(status: WorkStatus(summary: kind))
                    Text("\(summary.count(kind))")
                        .uiFont(10, bold: attention)
                        .foregroundStyle(Color(attention ? TermAppearance.red : TermAppearance.textPrimary).opacity(attention ? 1 : 0.85))
                }
                .padding(.horizontal, attention ? ui(5) : 0)
                .padding(.vertical, attention ? ui(1) : 0)
                .background {
                    if attention {
                        Capsule().fill(Color(TermAppearance.red).opacity(0.18))
                            .overlay(Capsule().strokeBorder(Color(TermAppearance.red).opacity(0.55), lineWidth: 1))
                    }
                }
            }
            if summary.runningAgents > 0 {
                Text("↳\(summary.runningAgents)")
                    .uiFont(10)
                    .foregroundStyle(Color(TermAppearance.yellow))
            }
            Text(summary.sessions > 0 ? "세션 \(summary.sessions)" : "세션 없음")
                .uiFont(10)
                .foregroundStyle(Color(TermAppearance.textDim))
        }
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        var parts = summary.entries.map { "\(WorkStatus(summary: $0.kind).label ?? "") \($0.count)" }
        if summary.runningAgents > 0 { parts.append("하위 에이전트 작업 중 \(summary.runningAgents)") }
        parts.append("세션 \(summary.sessions)")
        return parts.joined(separator: " · ")
    }
}

struct GroupRowView<MenuContent: View, ContextContent: View>: View {
    let group: FolderGroup
    let collapsed: Bool
    /// 접혔을 때만(안의 상태 합계)
    let summary: SpacesSummary?
    /// 접힌 묶음 안에 지금 고른 화면이 있다
    let holdsSelection: Bool
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @ViewBuilder let context: () -> ContextContent
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(alignment: .center, spacing: ui(6)) {
            // 화살표·이름 어디를 눌러도 접고 편다(+ 메뉴는 따로)
            HStack(alignment: .center, spacing: ui(6)) {
                DisclosureChevron(collapsed: collapsed, highlighted: hovering)
                StatusDot(status: WorkStatus.top(group.sections.flatMap { $0.rows.map(\.status) }))
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text(group.name)
                        .uiFont(12, bold: true)
                        .foregroundStyle(Color(TermAppearance.textPrimary))
                    // 접혔으면 둘째 줄 앞에 안의 상태 합계(이름은 폭을 그대로 쓴다)
                    HStack(spacing: ui(6)) {
                        if let summary { SpacesSummaryView(summary: summary) }
                        Text((summary == nil ? "" : "· ") + (group.branch ?? (group.path as NSString).abbreviatingWithTildeInPath))
                            .uiFont(10)
                            .foregroundStyle(Color(TermAppearance.textDim))
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            Menu {
                menu()
            } label: {
                Text("+").uiFont(13)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .help("이 폴더에서 새로 열기")
        }
        .padding(.leading, ui(8))
        .padding(.trailing, ui(10))
        .padding(.vertical, ui(6))
        .background(Color(holdsSelection || hovering ? TermAppearance.chromeRaised.withAlphaComponent(0.5) : .clear))
        .overlay(alignment: .leading) {
            if holdsSelection { Rectangle().fill(Color(TermAppearance.accent).opacity(0.7)).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { context() }
        .help(group.path + (collapsed ? "\n누르면 펼칩니다 · 끌어서 순서를 바꿉니다" : "\n누르면 접습니다 · 끌어서 순서를 바꿉니다"))
    }
}

struct WorktreeRowView: View {
    let section: WorktreeSection
    let collapsed: Bool
    let summary: SpacesSummary?
    let holdsSelection: Bool
    let onToggle: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(alignment: .center, spacing: ui(6)) {
            DisclosureChevron(collapsed: collapsed, highlighted: hovering)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: ui(10), weight: .semibold))
                .foregroundStyle(Color(section.isClaude ? TermAppearance.claudeColor : TermAppearance.textDim))
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(section.name)
                    .uiFont(11, bold: true)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                HStack(spacing: ui(6)) {
                    if let summary { SpacesSummaryView(summary: summary) }
                    Text((summary == nil || section.branch == nil ? "" : "· ") + (section.branch ?? ""))
                        .uiFont(10)
                        .foregroundStyle(Color(TermAppearance.textDim))
                }
            }
            Spacer(minLength: 4)
            if summary != nil {
                EmptyView()
            } else if section.agents.contains(where: \.isRunning) {
                Text("● 작업 중 \(section.agents.filter(\.isRunning).count)")
                    .uiFont(10, bold: true)
                    .foregroundStyle(Color(TermAppearance.yellow))
            } else if !section.agents.isEmpty {
                Text("최근 작업").uiFont(10).foregroundStyle(Color(TermAppearance.textDim))
            } else if section.rows.isEmpty {
                Text("세션 없음").uiFont(10).foregroundStyle(Color(TermAppearance.textDim).opacity(0.7))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, ui(14 + 7))
        .padding(.trailing, ui(10))
        .padding(.vertical, ui(4))
        .background(Color(holdsSelection || hovering ? TermAppearance.chromeRaised.withAlphaComponent(0.5) : .clear))
        .overlay(alignment: .leading) {
            if holdsSelection { Rectangle().fill(Color(TermAppearance.accent).opacity(0.7)).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .help((section.isClaude ? "claude 가 만든 작업 트리 · \(section.path)" : section.path) + (collapsed ? "\n누르면 펼칩니다" : "\n누르면 접습니다"))
    }
}

struct SessionRowView: View {
    let row: PaneRow
    let depth: Int
    let selected: Bool
    let tabNumber: Int?
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ui(8)) {
            StatusDot(status: row.status, dormant: row.dormant)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: ui(1)) {
                HStack(spacing: ui(4)) {
                    Text(row.title)
                        .uiFont(12, bold: selected)
                        .foregroundStyle(Color(TermAppearance.textPrimary))
                    if row.launchWarning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: ui(9)))
                            .foregroundStyle(Color(TermAppearance.red))
                    }
                }
                if row.dormant {
                    Text((row.isClaude || row.isCodex) ? "꺼짐 · 열면 \(row.program) 를 이어서 시작" : "꺼짐 · 열면 셸을 다시 시작")
                        .uiFont(10)
                        .foregroundStyle(Color(TermAppearance.textDim))
                } else {
                if case .orchestrating = row.status {
                    // 오케스트레이션 중: 남은 일 수가 핵심이라 줄을 하나 더 써서 잘리지 않게(폴더는 묶음 머리에 있다)
                    Text(row.status.label ?? "")
                        .foregroundStyle(Color(row.status.color))
                        .uiFont(10)
                    Text(row.status.detail ?? "")
                        .foregroundStyle(Color(TermAppearance.textPrimary).opacity(0.85))
                        .uiFont(10)
                } else {
                HStack(spacing: 0) {
                    if let label = row.status.label {
                        Text(label + " · ")
                            .foregroundStyle(Color(row.status.color))
                            .fontWeight(row.status.needsAttention ? .bold : .regular)
                    }
                    Text(row.status.detail ?? row.program)
                        .foregroundStyle(Color(row.agentColor))
                    // 제목이 이미 폴더 이름이면 같은 말을 되풀이하지 않고 터미널 장치로 구분한다
                    Text(" · \(row.title == row.folder ? (row.pane.tty ?? "") : row.folder)")
                        .foregroundStyle(Color(TermAppearance.textDim))
                }
                .uiFont(10)
                }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let tabNumber {
                Text("⌘\(tabNumber)")
                    .uiFont(10)
                    .foregroundStyle(Color(selected ? TermAppearance.accent : TermAppearance.textDim).opacity(0.8))
                    .help("탭 \(tabNumber)에 있음")
            }
        }
        .padding(.leading, ui(14 + CGFloat(depth) * 15))
        .padding(.trailing, ui(10))
        .padding(.vertical, ui(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(selected ? TermAppearance.chromeRaised : hovering ? TermAppearance.chromeRaised.withAlphaComponent(0.5) : .clear))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color(TermAppearance.accent)).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(row.name)\n\(row.cwd) · \(row.pane.tty ?? "")" + (row.launchWarning.map { "\n⚠ \($0)" } ?? ""))
    }
}

/// 왼쪽 목록 한 줄(묶음 머리·작업 트리·세션·묶음 사이 틈). 접힘·순서(SpacesState)를 입혀 펼친다.
enum SidebarItem: Identifiable, Equatable {
    /// summary: 접혔을 때만 안의 상태 합계
    case group(FolderGroup, collapsed: Bool, summary: SpacesSummary?)
    case worktree(WorktreeSection, group: String, collapsed: Bool, summary: SpacesSummary?)
    /// section: 이 세션이 든 칸(작업 트리 경로) — 끌어서 순서를 바꿀 수 있는 범위
    case session(PaneRow, depth: Int, group: String, section: String)
    /// 하위 에이전트(owner: 띄운 에이전트 화면 이름 — 다른 줄 아래에 있을 때만)
    case agent(SubagentActivity, depth: Int, owner: String?, group: String)
    case gap(String)

    var id: String {
        switch self {
        case .group(let group, _, _): return "g:" + group.path
        case .worktree(let section, _, _, _): return "w:" + section.path
        case .session(let row, _, _, _): return "s:" + row.id
        case .agent(let agent, _, _, _): return "a:" + agent.sessionId + agent.id
        case .gap(let path): return "gap:" + path
        }
    }

    /// 이 줄이 든 묶음(저장소·폴더 경로)
    var groupPath: String {
        switch self {
        case .group(let group, _, _): return group.path
        case .worktree(_, let group, _, _), .session(_, _, let group, _), .agent(_, _, _, let group): return group
        case .gap(let path): return path
        }
    }

    /// 끌어 놓을 자리 줄을 들여 쓸 너비
    var indent: CGFloat {
        switch self {
        case .session(_, let depth, _, _): return 14 + CGFloat(depth) * 15
        default: return 8
        }
    }

    static func flatten(_ groups: [FolderGroup], spaces: SpacesState = SpacesState()) -> [SidebarItem] {
        var items: [SidebarItem] = []
        let owners = Dictionary(groups.flatMap { $0.sections.flatMap(\.rows) }.map { ($0.id, $0.name) },
                                uniquingKeysWith: { first, _ in first })
        for group in SpacesOrder.apply(groups, order: spaces.groupOrder, id: \.path) {
            let collapsed = spaces.isCollapsed(SpacesState.groupKey(group.path))
            items.append(.group(group, collapsed: collapsed, summary: collapsed ? summary(group.sections) : nil))
            if !collapsed {
                for section in group.sections {
                    let depth = section.isMain ? 1 : 2
                    if !section.isMain {
                        let closed = spaces.isCollapsed(SpacesState.worktreeKey(section.path))
                        items.append(.worktree(section, group: group.path, collapsed: closed,
                                               summary: closed ? summary([section]) : nil))
                        if closed { continue }
                        // 이 작업 트리에서 일하는 하위 에이전트(띄운 claude 는 다른 줄에 있으므로 이름을 함께 보인다)
                        items += section.agents.map { .agent($0, depth: depth, owner: owners[$0.paneId], group: group.path) }
                    }
                    for row in SpacesOrder.apply(section.rows, order: spaces.sessionOrder, id: \.id) {
                        items.append(.session(row, depth: depth, group: group.path, section: section.path))
                        items += row.agents.map { .agent($0, depth: depth + 1, owner: nil, group: group.path) }
                    }
                }
            }
            items.append(.gap(group.path))
        }
        return items
    }

    /// 칸들 안의 세션·하위 에이전트 상태 합계(꺼진 화면은 상태 없이 세션으로만 센다)
    static func summary(_ sections: [WorktreeSection]) -> SpacesSummary {
        var summary = SpacesSummary()
        for section in sections {
            for row in section.rows {
                summary.add(session: row.dormant ? nil : row.status.summaryKind)
                row.agents.forEach { summary.add(agentRunning: $0.isRunning) }
            }
            section.agents.forEach { summary.add(agentRunning: $0.isRunning) }
        }
        return summary
    }

    /// 시험 명령 `spaces` 의 한 줄
    var debugLine: String {
        func counts(_ summary: SpacesSummary?) -> String {
            guard let summary else { return "" }
            return " summary=" + (summary.entries.map { "\($0.kind.rawValue):\($0.count)" } + ["agents:\(summary.runningAgents)", "sessions:\(summary.sessions)"])
                .joined(separator: ",")
        }
        switch self {
        case .group(let group, let collapsed, let summary):
            return "group \(group.path) collapsed=\(collapsed)" + counts(summary)
        case .worktree(let section, _, let collapsed, let summary):
            return "  worktree \(section.path) collapsed=\(collapsed)" + counts(summary)
        case .session(let row, let depth, _, _):
            return String(repeating: "  ", count: depth) + "session \(row.id.prefix(4)) \(row.name) status=\(row.status.debugName)"
        case .agent(let agent, let depth, _, _):
            return String(repeating: "  ", count: depth) + "agent \(agent.description) running=\(agent.isRunning)"
        case .gap: return "gap"
        }
    }
}

/// 끌어 놓을 자리 줄(강조색, 앞에 작은 고리)
struct InsertionLine: View {
    enum Edge { case above, below, middle }
    let edge: Edge
    let indent: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Color(TermAppearance.accent), lineWidth: 2).frame(width: 7, height: 7)
            Rectangle().fill(Color(TermAppearance.accent)).frame(height: 2)
        }
        .padding(.leading, indent - 3)
        .padding(.trailing, 8)
        .frame(maxHeight: edge == .middle ? .infinity : nil)
        .offset(y: edge == .above ? -3.5 : edge == .below ? 3.5 : 0)
        .allowsHitTesting(false)
    }
}

/// 목록 줄 하나에 끌어 놓기. 묶음은 다른 묶음의 아무 줄에, 세션은 같은 칸의 세션에만 놓을 수 있다(그 밖은 무시).
private struct SpacesDropDelegate: DropDelegate {
    let item: SidebarItem
    let items: [SidebarItem]
    let groups: [FolderGroup]
    let store: SpacesStore

    func validateDrop(info: DropInfo) -> Bool { store.drag != nil }

    func dropEntered(info: DropInfo) { update() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: update() ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        guard var drag = store.drag, let target = drag.target, target == drag.target(for: item) else { return }
        drag.target = nil
        store.drag = drag
    }

    func performDrop(info: DropInfo) -> Bool {
        guard store.drag != nil else { return false }
        let ok = update()
        store.finishDrag(groups: groups)
        return ok
    }

    /// 이 줄 위에 있을 때 놓을 자리를 정한다. 놓을 수 있으면 true.
    @discardableResult
    private func update() -> Bool {
        guard var drag = store.drag else { return false }
        let target = drag.target(for: item)
        let after = target.map { SpacesOrder.insertsAfter(drag.siblings(in: items), drag.id, onto: $0) } ?? false
        if drag.target != target || drag.after != after {
            drag.target = target
            drag.after = after
            store.drag = drag
        }
        return target != nil
    }
}

/// 하위 에이전트 한 줄. 누르면 띄운 에이전트 화면으로 넘어가고 마지막 메시지를 펼친다.
struct AgentRowView: View {
    let agent: SubagentActivity
    let depth: Int
    let owner: String?
    let expanded: Bool
    @State private var hovering = false

    @Environment(\.uiScale) private var ui

    private var when: String {
        if agent.isRunning { return "작업 중" }
        let minutes = max(1, Int(Date().timeIntervalSince(agent.lastActive) / 60))
        return "\(minutes)분 전"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui(4)) {
            HStack(alignment: .firstTextBaseline, spacing: ui(6)) {
                Text("↳")
                    .uiFont(11)
                    .foregroundStyle(Color(TermAppearance.textDim))
                VStack(alignment: .leading, spacing: ui(1)) {
                    Text(agent.description)
                        .uiFont(11)
                        .foregroundStyle(Color(agent.isRunning ? TermAppearance.textPrimary : TermAppearance.textDim))
                    HStack(spacing: 0) {
                        Text(when)
                            .foregroundStyle(Color(agent.isRunning ? TermAppearance.yellow : TermAppearance.textDim))
                        Text([agent.agentType, owner.map { "\($0) 의 하위 에이전트" }].compactMap { $0 }
                            .map { " · " + $0 }.joined())
                            .foregroundStyle(Color(TermAppearance.textDim))
                    }
                    .uiFont(10)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if expanded {
                Text(agent.lastText ?? "아직 남긴 메시지가 없습니다.")
                    .uiFont(10)
                    .foregroundStyle(Color(TermAppearance.textPrimary).opacity(0.85))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(ui(8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(TermAppearance.chromeRaised)))
            }
        }
        .padding(.leading, ui(14 + CGFloat(depth) * 15))
        .padding(.trailing, ui(10))
        .padding(.vertical, ui(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hovering ? TermAppearance.chromeRaised.withAlphaComponent(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("누르면 이 에이전트를 띄운 에이전트 화면으로 이동하고 마지막 메시지를 펼칩니다\n\(agent.worktreePath ?? "")")
    }
}

/// 도크 맨 아래 상태 줄: 새 버전·오류·요금제 사용량·메모리·버전·데몬 연결. 도구(spaces·files)와 상관없이 도크에 붙어 보인다.
struct StatusFooterView: View {
    @ObservedObject var model: TermModel
    @ObservedObject private var updates: UpdateNotifier
    @ObservedObject private var launch: LaunchSettings
    @ObservedObject private var usage: UsageStore
    @ObservedObject private var scaling = UIScaleModel.shared
    private var ui: UIScale { scaling.scale }

    init(model: TermModel) {
        _model = ObservedObject(wrappedValue: model)
        _launch = ObservedObject(wrappedValue: model.launch)
        _updates = ObservedObject(wrappedValue: model.updates)
        _usage = ObservedObject(wrappedValue: model.usage)
    }

    private static let versionLabel: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let label = [version.map { "v\($0)" }, build.map { "빌드 \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return label.isEmpty ? "개발 빌드" : label
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: ui(3)) {
            if let release = updates.available {
                UpdateLine(tag: UpdateNotifier.display(release.tag)) { updates.presentUpdate() }
                    .padding(.bottom, ui(3))
            }
            if model.legacyDaemon || model.relocating {
                LegacyDaemonLine(relocating: model.relocating) { model.moveToNewLocation() }
                    .padding(.bottom, ui(3))
            }
            if !model.migrationPending.isEmpty {
                NoticeLine(color: TermAppearance.yellow, title: "데이터 옮기기 일부 실패", detail: "다음 실행 때 다시 시도합니다",
                           help: DataLocation.pendingNoticeDetail(model.migrationPending, legacy: DataLocation.legacyRoot(),
                                                                  logPath: Self.logPath))
                    .padding(.bottom, ui(3))
            }
            if let error = model.lastError {
                Text(error).foregroundStyle(Color(TermAppearance.red))
            }
            if let claude = usage.claude { UsageLineView(line: claude) }
            if let codex = usage.codex { UsageLineView(line: codex) }
            Text("앱 \(Memory.format(model.appFootprint)) · 데몬 \(Memory.format(model.daemonFootprint))")
            HStack(alignment: .center, spacing: ui(6)) {
                Text(Self.versionLabel)
                    .textSelection(.enabled)
                Spacer(minLength: ui(4))
                SettingsButton(warning: launch.danger(.claude) ?? launch.danger(.codex)) { model.openSettings() }
            }
            daemonLine
        }
        .uiFont(10)
        .foregroundStyle(Color(TermAppearance.textDim))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ui(14))
        .padding(.vertical, ui(10))
        .background(Color(TermAppearance.chrome))
        .overlay(alignment: .top) { Rectangle().fill(Color(TermAppearance.border).opacity(0.5)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
        .environment(\.uiScale, ui)
    }

    private static var logPath: String { TermPaths.home.appendingPathComponent("daemon.log").path }

    /// 맨 아래 데몬 연결 줄: 평소엔 흐리게 한 줄, 붙는 중·실패·세션 유지 제한은 색 점과 함께 눈에 띄게
    @ViewBuilder private var daemonLine: some View {
        if model.connected {
            if model.link.limited {
                NoticeLine(color: TermAppearance.yellow, title: "세션 유지 제한", detail: "앱을 강제 종료하면 세션이 끝날 수 있음",
                           help: """
                               세션 데몬이 launchd 작업이 아니라 예전 방식(posix_spawn)으로 떠서 앱과 같은 묶음(coalition)에 있습니다.
                               앱을 ⌘Q 로 끄면 세션은 남지만, 강제 종료하거나 Dock 에서 강제 종료하면 셸·claude·codex 가 함께 끝날 수 있습니다.
                               모든 화면을 닫고 데몬이 끝난 뒤(약 1분) 앱을 다시 켜면 launchd 작업으로 다시 띄웁니다.
                               기록: \(Self.logPath)
                               """)
            } else {
                Text("앱을 꺼도 세션은 계속 돕니다")
            }
        } else if case .failed(let message, _) = model.link.phase {
            NoticeLine(color: TermAppearance.red, title: "세션 데몬에 연결하지 못함", detail: "잠시 뒤 다시 시도합니다",
                       help: "\(message) (\(model.link.failures)번째 실패)\n새 화면을 열면 바로 다시 시도합니다.\n기록: \(Self.logPath)")
        } else {
            NoticeLine(color: TermAppearance.yellow, title: model.connectionStatusText ?? "세션 데몬 연결 중…", detail: nil,
                       help: "세션 데몬에 연결하는 중입니다. 데몬이 없으면 띄웁니다(몇 초 걸릴 수 있음).\n기록: \(Self.logPath)")
        }
    }
}

/// 상태 줄의 알림: 색 점 + 밝은 제목 한 줄 + 설명 한 줄, 풍선 도움말에 자세한 내용.
/// 줄마다 한 줄로 자른다(상태 줄 높이를 NSHostingView 가 줄 바꿈 전 폭으로 재서, 접힌 줄은 아래가 잘렸다).
private struct NoticeLine: View {
    let color: NSColor
    let title: String
    let detail: String?
    let help: String
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ui(6)) {
            Circle().fill(Color(color)).frame(width: ui(6), height: ui(6))
            VStack(alignment: .leading, spacing: ui(1)) {
                Text(title)
                    .uiFont(11, bold: true)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                if let detail {
                    Text(detail)
                        .uiFont(10)
                        .foregroundStyle(Color(TermAppearance.textPrimary).opacity(0.85))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help)
    }
}

/// 상태 줄 오른쪽 "⚙ 설정"(⌘,). 새 세션 기본 옵션이 위험하면 빨간 ⚠ 를 덧붙인다.
private struct SettingsButton: View {
    let warning: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(4)) {
                if warning != nil {
                    Text("⚠").foregroundStyle(Color(TermAppearance.red))
                }
                Image(systemName: "gearshape")
                Text("설정")
            }
            .uiFont(11, bold: hovering)
            .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textDim))
            .padding(.horizontal, ui(7))
            .padding(.vertical, ui(3))
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color(hovering ? TermAppearance.chromeRaised : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(warning.map { "설정 (⌘,)\n기본 옵션 주의: \($0)" } ?? "설정 (⌘,)")
    }
}

/// 예전 데몬(예전 데이터 폴더)에서 실행 중일 때: 무엇이 언제 바뀌는지와 "지금 옮기기…"(경고 후 옮김)
private struct LegacyDaemonLine: View {
    let relocating: Bool
    let action: () -> Void
    @Environment(\.uiScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui(5)) {
            HStack(alignment: .firstTextBaseline, spacing: ui(6)) {
                Circle().fill(Color(TermAppearance.yellow)).frame(width: ui(6), height: ui(6))
                Text(relocating ? "새 위치로 옮기는 중…" : "이전 데몬에서 실행 중 — 재시작(또는 재부팅) 시 새 위치로 옮깁니다")
                    .uiFont(11)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !relocating {
                Button(action: action) {
                    Text("지금 옮기기…")
                        .uiFont(11, bold: true)
                        .foregroundStyle(Color(TermAppearance.chrome))
                        .padding(.horizontal, ui(10))
                        .padding(.vertical, ui(3))
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(TermAppearance.yellow)))
                }
                .buttonStyle(.plain)
                .help("예전 데몬을 끄고 데이터를 새 위치로 옮깁니다. 열린 셸·claude 가 멈추고, claude·codex 화면은 탭을 열면 되살아납니다.")
            }
        }
        .padding(ui(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(TermAppearance.yellow).opacity(0.6), lineWidth: 1))
    }
}

/// 상태 줄 맨 위 "새 버전 v0.x.y — 업데이트"(눈에 띄게 강조색, 누르면 업데이트 방법)
private struct UpdateLine: View {
    let tag: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(6)) {
                Circle().fill(Color(TermAppearance.accent)).frame(width: ui(6), height: ui(6))
                Text("새 버전 \(tag) — 업데이트")
                    .uiFont(11, bold: true)
                    .underline(hovering)
            }
            .foregroundStyle(Color(TermAppearance.accent))
            .padding(.horizontal, ui(8))
            .padding(.vertical, ui(4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(TermAppearance.accent).opacity(hovering ? 0.18 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("업데이트 명령과 릴리스 페이지 보기")
    }
}
