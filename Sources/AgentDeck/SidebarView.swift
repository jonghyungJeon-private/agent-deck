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
    /// 연결된 뒤 잠시 지나서야 켠다: 앱을 켜고 처음 목록이 채워지는 것은 움직이지 않는다
    @State private var motionReady = false
    /// "자세히"를 펼친 알림 하나(한 번에 하나만 — 붙박이 알림 칸이 목록을 다 밀어내지 않게)
    @State private var openNotice: String?
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
        // 묶음 접기·펼치기·줄 생김/사라짐은 줄 id 집합이 바뀔 때만 움직인다(끌어 놓아 순서만 바뀌는 것·글꼴 크기 바뀜은 그대로)
        let items = SidebarItem.flatten(model.groups, spaces: spaces.state)
        let listMotion = motionReady ? Motion.ease() : nil
        let hintOwners = tabHintOwners(items)
        return VStack(spacing: 0) {
            header
            // 알림은 머리 줄 바로 아래, 목록 밖에 붙박이로: 연결하기·갱신하기·받는 중 표시가 늘 손에 닿는다
            noticeStack
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.groups.isEmpty {
                        Text(model.connectionStatusText ?? "열린 세션이 없습니다.\n위 + 버튼으로 시작하세요.")
                            .uiTextFont(TypeSize.secondary)
                            .foregroundStyle(Color(TermAppearance.textSecondary))
                            .padding(.horizontal, ui(Space.md))
                            .padding(.vertical, ui(Space.md))
                    }
                    // 묶음·작업 트리·세션을 한 줄짜리 목록으로 펼쳐 그린다.
                    // ForEach 를 겹쳐 쓰면 안쪽 줄이 바뀐 것을 SwiftUI 가 놓쳐 이름이 늦게 바뀌었다.
                    ForEach(items) { item in
                        row(item, hintOwners: hintOwners)
                            .transition(rowTransition)
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
                .padding(.vertical, ui(Space.xs))
                .animation(listMotion, value: Set(items.map(\.id)))
            }
        }
        .animation(motionReady ? Motion.ease() : nil, value: noticeKey)
        .task(id: model.connected) {
            guard model.connected, !motionReady else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            motionReady = true
        }
        .frame(minWidth: 220, maxHeight: .infinity)
        .background(Color(TermAppearance.chrome))
        .environment(\.uiScale, ui)
    }

    /// 사라지는 줄은 빨리 걷히고(아래 줄이 올라오며 겹치기 전에), 생기는 줄은 아래 줄이 비켜 준 뒤에 서서히 나타난다.
    /// 켜는 동안(motionReady 전)은 움직임 없이 목록과 같이 바뀐다.
    private var rowTransition: AnyTransition {
        guard motionReady else { return .opacity }
        return .asymmetric(insertion: .opacity.animation(Motion.ease(Motion.standard)?.delay(Motion.exit)),
                           removal: .opacity.animation(Motion.ease(Motion.exit)))
    }

    @ViewBuilder
    private func row(_ item: SidebarItem, hintOwners: TabHintOwners) -> some View {
        switch item {
        case .group(let group, let collapsed, let summary):
            GroupRowView(group: group, collapsed: collapsed, summary: summary,
                         holdsSelection: collapsed && group.sections.contains { $0.rows.contains { $0.id == model.selectedId } },
                         hiddenTabs: hintOwners.collapsed[item.id] ?? [],
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
                            hiddenTabs: hintOwners.collapsed[item.id] ?? [],
                            onToggle: { spaces.toggle(SpacesState.worktreeKey(section.path)) })
                .contextMenu {
                    Button(collapsed ? "펼치기" : "접기") { spaces.toggle(SpacesState.worktreeKey(section.path)) }
                    Divider()
                    openMenu(section.path)
                }
        case .session(let row, let depth, _, let section):
            SessionRowView(row: row, depth: depth,
                           selected: row.id == model.selectedId,
                           tabNumber: model.workspace.tabIndex(containing: row.id).map { $0 + 1 },
                           showsTabHint: hintOwners.sessions.contains(row.id),
                           browser: model.browserIndicator(row.id),
                           openBrowser: { model.openBrowser(owner: row.id) })
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
                    withAnimation(Motion.ease()) { expandedAgent = expandedAgent == agent.id ? nil : agent.id }
                }
        case .gap:
            // 묶음 끝 틈: 묶음을 끌어 내릴 때 놓을 자리 줄이 여기 그려진다
            Color.clear.frame(height: ui(Space.md)).contentShape(Rectangle())
        }
    }

    /// ⌘N 힌트는 탭마다 한 번만: 보이는 줄 중 그 탭에서 입력을 받는 세션 줄(없으면 탭의 첫 보이는 세션 줄)에.
    /// 탭의 세션이 모두 접힌 묶음·작업 트리 안이면 그 접힌 줄에 보인다. 다른 줄은 풍선 도움말에만 적는다(보이는 것만 다르다).
    struct TabHintOwners {
        var sessions: Set<String> = []
        /// 접힌 묶음·작업 트리 줄 id → 그 안에 숨은 탭 번호(1부터)
        var collapsed: [String: [Int]] = [:]
    }

    private func tabHintOwners(_ items: [SidebarItem]) -> TabHintOwners {
        var out = TabHintOwners()
        var visible = Set<String>()
        for case .session(let row, _, _, _) in items { visible.insert(row.id) }
        // 숨은 세션이 든 가장 가까운 접힌 줄
        var hider: [String: String] = [:]
        for group in model.groups {
            let groupCollapsed = spaces.state.isCollapsed(SpacesState.groupKey(group.path))
            for section in group.sections {
                let key = groupCollapsed ? "g:" + group.path
                    : (!section.isMain && spaces.state.isCollapsed(SpacesState.worktreeKey(section.path))) ? "w:" + section.path : nil
                if let key { for row in section.rows { hider[row.id] = key } }
            }
        }
        for (index, tab) in model.workspace.tabs.enumerated() {
            let candidates = ([tab.focused] + tab.root.panes).filter { model.row($0) != nil }
            if let shown = candidates.first(where: { visible.contains($0) }) {
                out.sessions.insert(shown)
            } else if let key = candidates.lazy.compactMap({ hider[$0] }).first {
                out.collapsed[key, default: []].append(index + 1)
            }
        }
        return out
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
        HStack(spacing: ui(Space.xs)) {
            if showsTitle {
                Text("spaces")
                    .uiTextFont(TypeSize.secondary, weight: .semibold)
                    .foregroundStyle(Color(TermAppearance.textSecondary))
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
                HStack(spacing: ui(Space.xs)) {
                    agentButton(.claude)
                    agentButton(.codex)
                    ChromeButton(title: "셸", symbol: "plus", help: "홈 폴더에서 새 셸 탭 (지금 화면 폴더는 ⌘T)") {
                        model.newPane(cwd: NSHomeDirectory())
                    }
                }
                .fixedSize()
                Menu { newSessionItems } label: {
                    Label("새 세션", systemImage: "plus")
                }
                .uiTextFont(TypeSize.secondary)
                .fixedSize()
            }
        }
        .padding(.leading, ui(Space.md))
        .padding(.trailing, ui(Space.sm))
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

    /// 알림이 바뀌었는지(생김·사라짐 움직임의 기준)
    private var noticeKey: [String] { notices.map(\.id) + (model.notice == nil ? [] : ["info"]) }

    /// 머리 줄 아래·목록 위에 붙박이로 놓는 알림: hook·스킬·브라우저 연결이 필요하거나 막혔을 때, 한 줄 제목 + 작은 버튼, 설명은 "자세히".
    /// 버튼은 접히지 않는다(자세히는 설명만). 버튼이 있는 알림 중 맨 위(가장 급한 것) 하나만 강조 버튼으로 그린다.
    @ViewBuilder
    private var noticeStack: some View {
        let items = notices
        let info = model.notice
        if !items.isEmpty || info != nil {
            let prominent = items.first { $0.action != nil }?.id
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { notice in
                        NoticeRow(notice: notice, prominent: notice.id == prominent,
                                  expanded: Binding(get: { openNotice == notice.id },
                                                    set: { openNotice = $0 ? notice.id : nil }))
                            .transition(.opacity)
                    }
                    if let info {
                        InfoNoticeRow(text: info) { model.notice = nil }.transition(.opacity)
                    }
                }
                .padding(.vertical, ui(Space.xs))
                Rectangle().fill(Color(TermAppearance.border).opacity(0.5)).frame(height: 1)
            }
            .transition(.opacity)
        }
    }

    /// hook 이 없거나 예전 앱 것이면 눈에 띄게 알린다(이름·되살리기·상태 표시가 여기에 달려 있다)
    private var notices: [SidebarNotice] {
        var out: [SidebarNotice] = []
        switch model.hookState {
        case .missing:
            out.append(SidebarNotice(id: "claude-hook", symbol: "exclamationmark.triangle.fill", tint: TermAppearance.warning,
                                     title: "Claude Code 연결 필요",
                                     detail: "Claude Code 와 연결되지 않았습니다. 세션 이름·되살리기·상태 표시에 필요합니다.",
                                     action: claudeHookAction("연결하기")))
        case .update:
            out.append(SidebarNotice(id: "claude-hook", symbol: "arrow.triangle.2.circlepath", tint: TermAppearance.textSecondary,
                                     title: "Claude Code 연결 갱신 필요",
                                     detail: "Claude Code 연결이 예전 판(예전 이름 ClaudeTerm·ClaudeSessions 포함)이거나 다른 위치(옮기기 전 앱)를 가리킵니다. 갱신하면 이 앱으로 바로잡고, 앱을 지우거나 옮겨도 오류가 나지 않는 형태로 바꿉니다.",
                                     action: claudeHookAction("갱신하기")))
        case .error(let detail):
            out.append(SidebarNotice(id: "claude-hook", symbol: "exclamationmark.triangle.fill", tint: TermAppearance.statusAttention,
                                     title: "Claude Code 설정을 읽지 못함",
                                     detail: "Claude Code 설정을 읽지 못했습니다: \(detail)", action: nil))
        default: break
        }
        if model.codexHookState != .unknown && model.codexHookState != .ok {
            let update = model.codexHookState == .update
            let message = update
                ? "Codex 연결이 예전 판이거나 다른 위치의 앱을 가리킵니다. 갱신한 뒤 Codex의 /hooks 에서 훅을 다시 신뢰하세요."
                : "Codex의 권한 요청·완료 알림을 연결할 수 있습니다. 연결 후 Codex의 /hooks 에서 훅을 검토·신뢰하세요."
            if case .error(let detail) = model.codexHookState {
                out.append(SidebarNotice(id: "codex-hook", symbol: "exclamationmark.triangle.fill", tint: TermAppearance.statusAttention,
                                         title: "Codex 연결 오류", detail: message + "\n" + detail, action: nil))
            } else {
                out.append(SidebarNotice(id: "codex-hook", symbol: update ? "arrow.triangle.2.circlepath" : "link",
                                         tint: TermAppearance.textSecondary,
                                         title: update ? "Codex 연결 갱신 필요" : "Codex 알림 연결 가능",
                                         detail: message,
                                         // 제목이 이미 Codex 라고 말하므로 버튼은 Claude 줄과 같은 말
                                         action: SidebarNotice.Action(title: update ? "갱신하기" : "연결하기", help: nil) {
                                             model.connectCodexHooks()
                                         }))
            }
        }
        if let browser = browserNotice { out.append(browser) }
        return out
    }

    private func claudeHookAction(_ title: String) -> SidebarNotice.Action {
        SidebarNotice.Action(title: title,
                             help: "~/.claude/settings.json 에 세션 기록·작업 상태 hook 을 넣습니다(바꾸기 전 백업, 다른 hook 은 그대로). 앱을 지우면 hook 은 아무것도 하지 않습니다.") {
            model.connectHooks()
        }
    }

    /// 브라우저 준비: abx 스킬(Claude Code·Codex)과 에이전트 전용 브라우저(Chrome for Testing). abx 를 찾았을 때만 보인다.
    /// 떠 있는 데몬이 예전 판이면 그것부터 알린다(화면에 브라우저 연결이 안 된다).
    private var browserNotice: SidebarNotice? {
        let skill = model.browserSkillState
        let chrome = model.browserChrome
        let help = "abx 스킬(SKILL.md)을 Claude Code(~/.claude/skills/abx)·Codex(~/.agents/skills/abx)에 넣고(직접 둔 스킬은 그대로), 에이전트 전용 브라우저를 ~/.abx/browsers 에 받습니다."
        let prompt: (title: String, text: String, button: String?, symbol: String, tint: NSColor)? = {
            guard skill != .unknown else { return nil }
            if !model.daemonHasBrowser {
                return ("세션 데몬이 예전 판", "세션 데몬이 예전 판이라 화면에 브라우저가 연결되지 않습니다. 모든 세션을 닫고 앱을 끈 뒤 1분쯤 지나 다시 켜면(또는 재부팅) 새 데몬이 뜹니다.",
                        nil, "exclamationmark.triangle.fill", TermAppearance.warning)
            }
            if case .updateFailed(let detail) = skill {
                return ("abx 스킬 갱신 실패", "abx 스킬을 지금 abx 판으로 바꾸지 못했습니다 — \(detail)", "다시 시도",
                        "exclamationmark.triangle.fill", TermAppearance.statusAttention)
            }
            var needs: [String] = []
            if case .missing(let targets) = skill { needs.append("\(targets.joined(separator: "·"))에 abx 스킬 넣기") }
            switch chrome {
            case .installing(let percent):
                return ("에이전트 전용 브라우저 받는 중 \(percent)%", "에이전트 전용 브라우저(Chrome for Testing)를 받는 중… \(percent)%", nil,
                        "arrow.down.circle", TermAppearance.textSecondary)
            case .failed(let detail):
                return ("에이전트 전용 브라우저 받기 실패", "에이전트 전용 브라우저를 받지 못했습니다: \(detail)", "다시 시도",
                        "exclamationmark.triangle.fill", TermAppearance.statusAttention)
            case .missing:
                needs.append("에이전트 전용 브라우저(Chrome for Testing, 약 190MB) 받기 — 받기 전에는 설치된 Chrome 을 씁니다")
            default: break
            }
            guard !needs.isEmpty else { return nil }
            return ("브라우저 연결 필요",
                    "브라우저 연결: " + needs.joined(separator: ", ") + ". 연결하면 에이전트가 abx 로 브라우저를 쓰고, 화면 제목 줄 🌐 로 볼 수 있습니다.",
                    skill == .ok || skill == .unknown ? "브라우저 받기" : "브라우저 연결하기",
                    "globe", TermAppearance.textSecondary)
        }()
        guard let prompt else { return nil }
        return SidebarNotice(id: "browser", symbol: prompt.symbol, tint: prompt.tint, title: prompt.title, detail: prompt.text,
                             action: prompt.button.map { title in
                                 SidebarNotice.Action(title: title, help: help) {
                                     if case .updateFailed = skill { model.checkBrowserSkill() } else { model.connectBrowserSkill() }
                                 }
                             })
    }

    /// 폴더·작업 트리에서 새로 열기
    @ViewBuilder
    private func openMenu(_ path: String) -> some View {
        Button("여기서 claude 열기(새 탭)") { model.newAgent(.claude, cwd: path) }
        Button("여기서 codex 열기(새 탭)") { model.newAgent(.codex, cwd: path) }
        Button("여기서 셸 열기(새 탭)") { model.newPane(cwd: path) }
        Button("Finder 에서 보기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    }

    /// + claude·+ codex: 기본 옵션이 위험하면 경고 표시를 붙이고, 풍선 도움말에 실제 명령을 보인다
    private func agentButton(_ kind: AgentKind) -> some View {
        let warning = launch.danger(kind)
        return ChromeButton(title: kind.rawValue, symbol: "plus", warning: warning != nil,
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

/// 사이드바 버튼 공통 눌림 모양: 누르는 동안 살짝 흐려질 뿐 크기는 그대로(튕기지 않는다). 눌리는 순간 바로, 뗄 때만 부드럽게.
struct SidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(configuration.isPressed ? nil : Motion.ease(Motion.fast), value: configuration.isPressed)
    }
}

/// 사이드바 위 글자 버튼: (선택) 그림 + 이름(+ 경고). 누르는 자리는 높이 24.
struct ChromeButton: View {
    let title: String
    var symbol: String? = nil
    /// 기본 옵션이 위험할 때 이름 뒤에 노란 경고 표시
    var warning = false
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(Space.xs)) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: ui(TypeSize.caption), weight: .semibold))
                }
                Text(title)
                    .uiTextFont(TypeSize.secondary, weight: .medium)
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: ui(TypeSize.caption)))
                        .foregroundStyle(Color(TermAppearance.warning))
                        .accessibilityLabel("주의")
                }
            }
            .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textSecondary))
            .padding(.horizontal, ui(Space.sm))
            .frame(height: ui(Space.xxl))
            .background(RoundedRectangle(cornerRadius: ui(6)).fill(Color(TermAppearance.chromeRaised)).opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
            .animation(Motion.ease(Motion.fast), value: hovering)
        }
        .buttonStyle(SidebarPressStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 사이드바 위 그림 버튼(글자 버튼과 같은 모양). 누르는 자리 24×24. 그림이 바뀌면(접기↔펼치기) 겹쳐 바뀐다.
struct IconChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: ui(TypeSize.secondary), weight: .medium))
                    .id(symbol)
                    .transition(.opacity)
            }
            .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textSecondary))
            .frame(width: ui(Space.xxl), height: ui(Space.xxl))
            .background(RoundedRectangle(cornerRadius: ui(6)).fill(Color(TermAppearance.chromeRaised)).opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
            .animation(Motion.ease(Motion.fast), value: hovering)
            .animation(Motion.ease(Motion.fast), value: symbol)
        }
        .buttonStyle(SidebarPressStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 목록 위 알림 한 건(알림 줄이 그린다). 기호 색: 안내·갱신은 중립, 경고는 노랑, 오류는 빨강(강조색은 버튼에만).
struct SidebarNotice: Identifiable {
    /// 알림 오른쪽 버튼(SwiftUI 의 Button 과 이름이 겹치지 않게 Action)
    struct Action {
        let title: String
        let help: String?
        let action: () -> Void
    }
    let id: String
    let symbol: String
    let tint: NSColor
    /// 한 줄 제목(설명의 요약)
    let title: String
    /// 전체 설명("자세히"로 펼친다)
    let detail: String?
    let action: Action?
}

/// 알림 버튼: 작은 테두리 버튼, 가장 급한 하나만 강조색 채움
private struct NoticeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        NoticeButtonBody(label: configuration.label, pressed: configuration.isPressed, prominent: prominent)
    }
}

private struct NoticeButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let prominent: Bool
    @Environment(\.uiScale) private var ui

    var body: some View {
        label
            .uiTextFont(TypeSize.secondary, weight: .semibold)
            .foregroundStyle(Color(prominent ? TermAppearance.onAccent : TermAppearance.textPrimary))
            .lineLimit(1)
            .padding(.horizontal, ui(Space.sm))
            .frame(minHeight: ui(Space.xxl))
            .background(RoundedRectangle(cornerRadius: ui(6))
                .fill(Color(prominent ? TermAppearance.accentFill : TermAppearance.chromeRaised)))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: ui(6)).strokeBorder(Color(TermAppearance.border), lineWidth: 1)
                }
            }
            .brightness(pressed ? -0.08 : 0)
            .animation(pressed ? nil : Motion.ease(Motion.fast), value: pressed)
            .contentShape(Rectangle())
    }
}

/// 알림 한 줄(모든 알림이 같은 모양): 첫 줄 [기호 · 한 줄 제목], 둘째 줄 [자세히 … 버튼(오른쪽)]. 설명은 자세히를 눌러야 펼친다.
private struct NoticeRow: View {
    let notice: SidebarNotice
    let prominent: Bool
    @Binding var expanded: Bool
    @Environment(\.uiScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui(2)) {
            HStack(alignment: .firstTextBaseline, spacing: ui(Space.sm)) { icon; title }
            HStack(alignment: .center, spacing: ui(Space.sm)) {
                disclosure.padding(.leading, ui(Space.xl))
                Spacer(minLength: ui(Space.sm))
                actionButton
            }
            if expanded, let detail = notice.detail {
                Text(detail)
                    .uiTextFont(TypeSize.secondary)
                    .foregroundStyle(Color(TermAppearance.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, ui(Space.xl))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, ui(Space.md))
        .padding(.vertical, ui(Space.xs))
    }

    private var icon: some View {
        Image(systemName: notice.symbol)
            .font(.system(size: ui(TypeSize.secondary), weight: .semibold))
            .foregroundStyle(Color(notice.tint))
            .frame(width: ui(Space.md), alignment: .leading)
    }

    private var title: some View {
        Text(notice.title)
            .uiTextFont(TypeSize.secondary, weight: .semibold)
            .foregroundStyle(Color(TermAppearance.textPrimary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var disclosure: some View {
        if notice.detail != nil {
            // 상태는 바로 바뀌고 보이는 것(펼침·화살표)만 부드럽게
            Button { withAnimation(Motion.ease()) { expanded.toggle() } } label: {
                HStack(spacing: ui(2)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: ui(TypeSize.caption), weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("자세히").uiTextFont(TypeSize.caption)
                }
                .foregroundStyle(Color(TermAppearance.textSecondary))
                .frame(minHeight: ui(Space.lg))
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarPressStyle())
            .accessibilityLabel(expanded ? "자세히 접기" : "자세히 보기")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action = notice.action {
            let button = Button(action.title, action: action.action)
                .buttonStyle(NoticeButtonStyle(prominent: prominent))
            if let help = action.help { button.help(help) } else { button }
        }
    }
}

/// 결과 알림(model.notice): 한 줄 안내, 누르면 닫는다
private struct InfoNoticeRow: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ui(Space.sm)) {
            Image(systemName: "info.circle")
                .font(.system(size: ui(TypeSize.secondary), weight: .semibold))
                .frame(width: ui(Space.md), alignment: .leading)
            Text(text)
                .uiTextFont(TypeSize.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(TermAppearance.textSecondary))
        .padding(.horizontal, ui(Space.md))
        .padding(.vertical, ui(Space.xs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityAddTraits(.isButton)
    }
}

/// 한 줄 목록 칸의 바탕 짙기: 고른 줄 > 고른 줄을 품은 접힌 줄 > 마우스가 올라온 줄. 셋이 서로 확실히 다르다.
/// (바탕 위 4.5:1 글자 대비 때문에 고른 줄의 채움을 더 어둡게 할 수 없어, 고른 줄만 얇은 테두리를 더 두른다.)
private enum PillLevel {
    static let none = 0.0
    static let hover = 0.4
    static let holdsSelection = 0.7
    static let selected = 1.0
}

/// 한 줄 목록 칸의 바탕: 둘레를 4pt 띄운 둥근 채움. 짙기(level)는 `PillLevel`, 고른 줄(level 1)만 `border` 테두리를 더한다.
/// 늘 그려 두고 짙기만 바꿔 서서히 겹쳐 바뀐다(고른 줄이 옮겨 가면 앞 줄은 옅어지고 새 줄은 짙어진다).
private extension View {
    func sidebarPill(_ level: Double, _ ui: UIScale) -> some View {
        background {
            RoundedRectangle(cornerRadius: ui(6)).fill(Color(TermAppearance.chromeRaised))
                .opacity(level)
                .overlay {
                    RoundedRectangle(cornerRadius: ui(6)).strokeBorder(Color(TermAppearance.border), lineWidth: 1)
                        .opacity(level >= PillLevel.selected ? 1 : 0)
                }
                .padding(.horizontal, ui(Space.xs))
                .animation(Motion.ease(Motion.fast), value: level)
        }
    }
}

/// 상태 점(8pt). 모양은 `WorkStatus.dotShape`: 작업 중·완료·상태 없음 = 찬 점, 쉬는 중·꺼진 화면 = 속 빈 고리, 입력 대기 = 테두리 두른 점 ◉,
/// 오케스트레이션 = 점선 고리 + 가운데 점, 오류 = 찬 점에 "!" 뚫기(색만으로 구분하지 않는다). 작업 중은 공용 시계로 숨 쉰다(`.workingPulse`).
/// 상태가 바뀌면 `Motion.fast` 로 겹쳐 바뀐다.
struct StatusDot: View {
    let status: WorkStatus
    var dormant = false
    @Environment(\.uiScale) private var ui

    private var shape: WorkStatus.DotShape { dormant ? .ring : status.dotShape }

    var body: some View {
        let color = Color(dormant ? TermAppearance.statusNone : status.color)
        Group {
            switch shape {
            case .ring:
                Circle().strokeBorder(color, lineWidth: 1.2)
            case .ringedDot:
                Circle().fill(color).padding(2).overlay(Circle().strokeBorder(color, lineWidth: 1))
            case .dottedRing:
                // 점선 고리(돌고 있는 일들) + 가운데 작은 점(메인)
                Circle().fill(color).padding(ui(2.6))
                    .overlay(Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [1.8, 1.3])))
            case .errorMark:
                // 찬 점에서 "!" 를 뚫어 낸다(막대 + 점)
                ZStack {
                    Circle().fill(color)
                    VStack(spacing: ui(0.9)) {
                        RoundedRectangle(cornerRadius: ui(0.6)).frame(width: ui(1.4), height: ui(3.2))
                        Circle().frame(width: ui(1.5), height: ui(1.5))
                    }
                    .blendMode(.destinationOut)
                }
                .compositingGroup()
            case .filled:
                Circle().fill(color)
            }
        }
        .frame(width: ui(8), height: ui(8))
        .workingPulse(status.pulses && !dormant)
        .animation(Motion.ease(Motion.fast), value: shape)
        .animation(Motion.ease(Motion.fast), value: status.color)
    }
}

/// 접기 화살표(▸ 접힘, ▾ 펼침)
struct DisclosureChevron: View {
    let collapsed: Bool
    var highlighted = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: ui(TypeSize.caption), weight: .semibold))
            .foregroundStyle(Color(highlighted ? TermAppearance.textPrimary : TermAppearance.textSecondary))
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .frame(width: ui(TypeSize.caption), height: ui(TypeSize.caption))
            .animation(Motion.ease(), value: collapsed)
            .animation(Motion.ease(Motion.fast), value: highlighted)
    }
}

/// 접힌 줄의 상태 합계: 상태 점 + 수(입력 대기·오류는 붉은 바탕으로 눈에 띄게), 일하는 하위 에이전트, 세션 수
struct SpacesSummaryView: View {
    let summary: SpacesSummary
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(spacing: ui(Space.xs)) {
            ForEach(SpacesSummary.Kind.allCases.filter { summary.count($0) > 0 }, id: \.self) { kind in
                let attention = kind == .waiting || kind == .error
                HStack(spacing: ui(3)) {
                    StatusDot(status: WorkStatus(summary: kind))
                    Text("\(summary.count(kind))")
                        .uiFont(TypeSize.caption, bold: attention)
                        .foregroundStyle(Color(attention ? TermAppearance.statusAttention : TermAppearance.textPrimary))
                }
                .padding(.horizontal, attention ? ui(5) : 0)
                .padding(.vertical, attention ? ui(1) : 0)
                .background {
                    if attention {
                        Capsule().fill(Color(TermAppearance.statusAttention).opacity(0.14))
                            .overlay(Capsule().strokeBorder(Color(TermAppearance.statusAttention).opacity(0.55), lineWidth: 1))
                    }
                }
            }
            if summary.runningAgents > 0 {
                HStack(spacing: ui(2)) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: ui(TypeSize.caption), weight: .semibold))
                    Text("\(summary.runningAgents)").uiFont(TypeSize.caption)
                }
                .foregroundStyle(Color(TermAppearance.statusWorking))
            }
            Text(summary.sessions > 0 ? "세션 \(summary.sessions)" : "세션 없음")
                .uiTextFont(TypeSize.caption)
                .foregroundStyle(Color(TermAppearance.textSecondary))
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

/// 한 줄 제목 + 곁 정보. 한 줄에 다 들어가면 오른쪽에, 모자라면 곁 정보(브랜치·경로)를 둘째 줄로 내린다 — 가린 채 두지 않는다.
private struct TitleWithAside<Title: View, Aside: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let aside: () -> Aside
    @Environment(\.uiScale) private var ui

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ui(Space.sm)) {
                title()
                Spacer(minLength: 0)
                aside()
            }
            VStack(alignment: .leading, spacing: ui(2)) {
                title()
                aside()
            }
        }
    }
}

/// 제목 줄 한 줄의 높이(둘째 줄이 있어도 화살표·점·+ 는 이 첫 줄에 맞춘다)
private func titleLineHeight(_ ui: UIScale, size: CGFloat, bold: Bool) -> CGFloat {
    let font = TermAppearance.uiFont(ui(size), bold: bold)
    return ceil(font.ascender - font.descender + font.leading)
}

/// 접힌 줄 안에 숨은 탭의 ⌘N(그 탭의 세션이 모두 접힌 줄 안에 있을 때 대신 보인다)
private struct HiddenTabHints: View {
    let tabs: [Int]

    var body: some View {
        Text(tabs.map { "⌘\($0)" }.joined(separator: " "))
            .uiFont(TypeSize.caption)
            .foregroundStyle(Color(TermAppearance.textSecondary))
            .lineLimit(1)
            .help(tabs.map { "탭 \($0)의 세션이 이 안에 있음" }.joined(separator: "\n"))
    }
}

/// 묶음(폴더·저장소) 머리 줄: 구역 이름표처럼 조용하게(작은 굵은 글, 보조 색). 세션 줄이 이 목록의 주인공이다.
struct GroupRowView<MenuContent: View, ContextContent: View>: View {
    let group: FolderGroup
    let collapsed: Bool
    /// 접혔을 때만(안의 상태 합계)
    let summary: SpacesSummary?
    /// 접힌 묶음 안에 지금 고른 화면이 있다
    let holdsSelection: Bool
    /// 접힌 묶음 안에 숨은 탭 번호(⌘N 힌트가 이 줄로 온다)
    var hiddenTabs: [Int] = []
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @ViewBuilder let context: () -> ContextContent
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        let line = titleLineHeight(ui, size: TypeSize.secondary, bold: true)
        // 화살표·점·+ 는 제목 줄(첫 줄)의 가운데에 맞춘다 — 둘째 줄(브랜치·합계)이 있어도 같은 높이
        HStack(alignment: .top, spacing: 0) {
            DisclosureChevron(collapsed: collapsed, highlighted: hovering)
                .frame(width: ui(Space.lg), height: line, alignment: .leading)
            StatusDot(status: WorkStatus.top(group.sections.flatMap { $0.rows.map(\.status) }))
                .frame(width: ui(Space.lg), height: line, alignment: .leading)
            VStack(alignment: .leading, spacing: ui(2)) {
                TitleWithAside {
                    Text(group.name)
                        .uiFont(TypeSize.secondary, bold: true)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } aside: {
                    Text(group.branch ?? (group.path as NSString).abbreviatingWithTildeInPath)
                        .uiFont(TypeSize.caption)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // 접혔으면 다음 줄에 안의 상태 합계(+ 숨은 탭의 ⌘N)
                if let summary {
                    HStack(spacing: ui(Space.sm)) {
                        SpacesSummaryView(summary: summary)
                        if !hiddenTabs.isEmpty { HiddenTabHints(tabs: hiddenTabs) }
                    }
                }
            }
            Spacer(minLength: ui(Space.xs))
        }
        // 화살표·이름 어디를 눌러도 접고 편다(+ 메뉴는 따로, 오른쪽 끝)
        .padding(.trailing, ui(Space.xxl))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .overlay(alignment: .topTrailing) {
            Menu {
                menu()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: ui(TypeSize.row), weight: .medium))
                    .foregroundStyle(Color(TermAppearance.textSecondary))
                    .frame(width: ui(Space.xxl), height: ui(Space.xxl))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(SidebarPressStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .offset(y: (line - ui(Space.xxl)) / 2)
            .help("이 폴더에서 새로 열기")
        }
        .padding(.leading, ui(Space.md))
        .padding(.trailing, ui(Space.xs))
        .padding(.vertical, ui(Space.xs))
        .sidebarPill(holdsSelection ? PillLevel.holdsSelection : hovering ? PillLevel.hover : PillLevel.none, ui)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { context() }
        .help(group.path + (group.branch.map { "\n브랜치 \($0)" } ?? "")
              + (collapsed ? "\n누르면 펼칩니다 · 끌어서 순서를 바꿉니다" : "\n누르면 접습니다 · 끌어서 순서를 바꿉니다"))
    }
}

/// 작업 트리(worktree) 줄: 묶음 머리 아래 한 단계 들여, 묶음보다 더 조용하게(굵지 않은 보조 색 글)
struct WorktreeRowView: View {
    let section: WorktreeSection
    let collapsed: Bool
    let summary: SpacesSummary?
    let holdsSelection: Bool
    var hiddenTabs: [Int] = []
    let onToggle: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        let line = titleLineHeight(ui, size: TypeSize.secondary, bold: false)
        HStack(alignment: .top, spacing: 0) {
            DisclosureChevron(collapsed: collapsed, highlighted: hovering)
                .frame(width: ui(Space.lg), height: line, alignment: .leading)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: ui(TypeSize.caption), weight: .semibold))
                .foregroundStyle(Color(section.isClaude ? TermAppearance.typeClaude : TermAppearance.textSecondary))
                .frame(width: ui(Space.lg), height: line, alignment: .leading)
            VStack(alignment: .leading, spacing: ui(2)) {
                TitleWithAside {
                    Text(section.name)
                        .uiFont(TypeSize.secondary)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } aside: {
                    if let branch = section.branch {
                        Text(branch)
                            .uiFont(TypeSize.caption)
                            .foregroundStyle(Color(TermAppearance.textSecondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let summary {
                    HStack(spacing: ui(Space.sm)) {
                        SpacesSummaryView(summary: summary)
                        if !hiddenTabs.isEmpty { HiddenTabHints(tabs: hiddenTabs) }
                    }
                }
            }
            Spacer(minLength: ui(Space.sm))
            if summary == nil {
                trailing.frame(height: line)
            }
        }
        .lineLimit(1)
        .padding(.leading, ui(Space.md + Space.lg))
        .padding(.trailing, ui(Space.md))
        .padding(.vertical, ui(Space.xs))
        .sidebarPill(holdsSelection ? PillLevel.holdsSelection : hovering ? PillLevel.hover : PillLevel.none, ui)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .help((section.isClaude ? "claude 가 만든 작업 트리 · \(section.path)" : section.path)
              + (section.branch.map { "\n브랜치 \($0)" } ?? "")
              + (collapsed ? "\n누르면 펼칩니다" : "\n누르면 접습니다"))
    }

    /// 오른쪽 끝 한마디(펼쳐 있을 때만): 일하는 하위 에이전트 수·최근 작업·세션 없음
    @ViewBuilder
    private var trailing: some View {
        if section.agents.contains(where: \.isRunning) {
            HStack(spacing: ui(Space.xs)) {
                Circle().fill(Color(TermAppearance.statusWorking)).frame(width: ui(6), height: ui(6)).workingPulse(true)
                Text("작업 중 \(section.agents.filter(\.isRunning).count)")
                    .uiTextFont(TypeSize.caption, weight: .semibold)
            }
            .foregroundStyle(Color(TermAppearance.textSecondary))
        } else if !section.agents.isEmpty {
            Text("최근 작업").uiTextFont(TypeSize.caption).foregroundStyle(Color(TermAppearance.textSecondary))
        } else if section.rows.isEmpty {
            Text("세션 없음").uiTextFont(TypeSize.caption).foregroundStyle(Color(TermAppearance.textSecondary))
        }
    }
}

struct SessionRowView: View {
    let row: PaneRow
    let depth: Int
    let selected: Bool
    let tabNumber: Int?
    /// ⌘N 힌트를 이 줄에 보인다(탭마다 한 줄만). 아니면 풍선 도움말에만 적는다.
    var showsTabHint = true
    /// 이 세션의 브라우저(떠 있을 때만). spaces 는 상태판이라 브라우저 사용 여부도 보인다
    var browser: BrowserIndicator? = nil
    var openBrowser: () -> Void = {}
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // 점 + 종류 아이콘은 이름 칸 왼쪽에 걸어 둔다(줄 왼쪽 여백에서 그만큼 덜어 냄) — 이름·둘째 줄은 예전 자리(묶음 이름과 같은 칸) 그대로
            StatusDot(status: row.status, dormant: row.dormant)
                .frame(width: ui(SidebarItem.dotColumn), alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            SessionKindIcon(kind: row.sessionKind, size: ui(TypeSize.caption))
                .frame(width: ui(SidebarItem.iconColumn), alignment: .leading)
            VStack(alignment: .leading, spacing: ui(2)) {
                HStack(spacing: ui(Space.xs)) {
                    Text(row.title)
                        .uiFont(TypeSize.row)
                        .foregroundStyle(Color(TermAppearance.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.launchWarning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: ui(TypeSize.caption)))
                            .foregroundStyle(Color(TermAppearance.warning))
                    }
                }
                detail
            }
            .lineLimit(1)
            Spacer(minLength: ui(Space.sm))
            if let browser {
                // 🌐 + 상태 색(기다림은 !) — 누르면 그 세션의 브라우저 창
                HStack(spacing: ui(2)) {
                    Image(systemName: "globe")
                        .font(.system(size: ui(TypeSize.row), weight: .semibold))
                    if browser.needsAttention {
                        Text("!").uiFont(TypeSize.caption, bold: true)
                    }
                }
                .foregroundStyle(Color(browser.color))
                .padding(.horizontal, ui(Space.xs))
                .padding(.vertical, ui(1))
                .background(Capsule().fill(Color(browser.color).opacity(browser.needsAttention ? 0.22 : 0.12)))
                .overlay(Capsule().strokeBorder(Color(browser.color).opacity(browser.needsAttention ? 1 : 0.55), lineWidth: 1))
                // 누르는 자리를 넉넉히(작은 지구본만이 아니라 둘레까지)
                .frame(minWidth: ui(Space.xxl), minHeight: ui(22))
                .contentShape(Rectangle())
                .help("브라우저 · \(browser.label) — 눌러서 창 열기")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("브라우저 \(browser.label)")
                .accessibilityAddTraits(.isButton)
                .onTapGesture(perform: openBrowser)
                .padding(.leading, ui(Space.xs))
            }
            if let tabNumber, showsTabHint {
                Text("⌘\(tabNumber)")
                    .uiFont(TypeSize.caption)
                    .foregroundStyle(Color(selected ? TermAppearance.textPrimary : TermAppearance.textSecondary))
                    .help("탭 \(tabNumber)에 있음")
                    .padding(.leading, ui(Space.xs))
            }
        }
        .padding(.leading, ui(SidebarItem.sessionHang(depth: depth)))
        .padding(.trailing, ui(Space.md))
        .padding(.vertical, ui(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarPill(selected ? PillLevel.selected : hovering ? PillLevel.hover : PillLevel.none, ui)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(row.name)\n\(row.cwd) · \(row.pane.tty ?? "")" + (row.launchWarning.map { "\n⚠ \($0)" } ?? "")
              + (tabNumber.map { showsTabHint ? "" : "\n탭 \($0)에 있음" } ?? ""))
    }

    /// 둘째 줄: 상태 · 프로그램(또는 상태 설명) · 폴더. 이름·tty 같은 데이터는 고정폭, 상태 말은 시스템 글꼴.
    @ViewBuilder
    private var detail: some View {
        if row.dormant {
            Text((row.isClaude || row.isCodex) ? "꺼짐 · 열면 \(row.program) 를 이어서 시작" : "꺼짐 · 열면 셸을 다시 시작")
                .uiTextFont(TypeSize.caption)
                .foregroundStyle(Color(TermAppearance.textSecondary))
        } else if case .orchestrating = row.status {
            // 오케스트레이션 중: 남은 일 수가 핵심이라 줄을 하나 더 써서 잘리지 않게(폴더는 묶음 머리에 있다)
            Text(row.status.label ?? "")
                .foregroundStyle(Color(row.status.color))
                .uiTextFont(TypeSize.caption)
            Text(row.status.detail ?? "")
                .foregroundStyle(Color(TermAppearance.textPrimary))
                .uiTextFont(TypeSize.caption)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let label = row.status.label {
                    Text(label + " · ")
                        .uiTextFont(TypeSize.caption, weight: row.status.needsAttention ? .bold : .regular)
                        .foregroundStyle(Color(row.status.color))
                        .layoutPriority(2)
                }
                Group {
                    // 프로그램 단어는 종류 색(셸은 회색), 상태 설명은 보조 글자색
                    if let detail = row.status.detail {
                        Text(detail).uiTextFont(TypeSize.caption).foregroundStyle(Color(TermAppearance.textSecondary))
                    } else {
                        Text(row.program).uiFont(TypeSize.caption).foregroundStyle(Color(row.sessionKind.color))
                    }
                }
                .layoutPriority(1)
                // 제목이 이미 폴더 이름이면 같은 말을 되풀이하지 않고 터미널 장치로 구분한다
                Text(" · \(row.title == row.folder ? (row.pane.tty ?? "") : row.folder)")
                    .uiFont(TypeSize.caption)
                    .foregroundStyle(Color(TermAppearance.textSecondary))
                    .truncationMode(.middle)
            }
        }
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

    /// 끌어 놓을 자리 줄을 들여 쓸 너비(줄의 첫 칸과 같은 자리, 배율 곱하기 전)
    var indent: CGFloat {
        switch self {
        case .session(_, let depth, _, _): return Self.sessionHang(depth: depth)
        default: return Space.md
        }
    }

    /// 세션 줄 왼쪽 여백(배율 곱하기 전). 점 칸(`dotColumn`) + 종류 아이콘 칸(`iconColumn`)은 이름 칸 왼쪽에 걸려 있어서,
    /// 이름은 점 칸 하나(`Space.lg`)만 있던 때와 같은 자리(`Space.md + depth * Space.lg + Space.lg`)에 선다.
    static func sessionHang(depth: Int) -> CGFloat { CGFloat(depth) * Space.lg }
    /// 점 칸(8pt 점 + 2pt 여유)과 종류 아이콘 칸(가장 넓은 ‹› 도 이름과 4pt 이상 떨어지게). 합 28 = 걸리는 폭.
    static let dotColumn: CGFloat = 10
    static let iconColumn: CGFloat = 18

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
        VStack(alignment: .leading, spacing: ui(Space.xs)) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: ui(TypeSize.caption), weight: .semibold))
                    .foregroundStyle(Color(TermAppearance.textSecondary))
                    .frame(width: ui(Space.lg), alignment: .leading)
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text(agent.description)
                        .uiFont(TypeSize.secondary)
                        .foregroundStyle(Color(agent.isRunning ? TermAppearance.textPrimary : TermAppearance.textSecondary))
                    HStack(spacing: 0) {
                        Text(when)
                            .foregroundStyle(Color(agent.isRunning ? TermAppearance.statusWorking : TermAppearance.textSecondary))
                        Text([agent.agentType, owner.map { "\($0) 의 하위 에이전트" }].compactMap { $0 }
                            .map { " · " + $0 }.joined())
                            .foregroundStyle(Color(TermAppearance.textSecondary))
                    }
                    .uiTextFont(TypeSize.caption)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if expanded {
                Text(agent.lastText ?? "아직 남긴 메시지가 없습니다.")
                    .uiTextFont(TypeSize.caption)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(ui(Space.sm))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: ui(6)).fill(Color(TermAppearance.chromeRaised)))
                    .transition(.opacity)
            }
        }
        .padding(.leading, ui(Space.md + CGFloat(depth) * Space.lg))
        .padding(.trailing, ui(Space.md))
        .padding(.vertical, ui(Space.xs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarPill(hovering ? PillLevel.hover : PillLevel.none, ui)
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
        VStack(alignment: .leading, spacing: ui(Space.xs)) {
            if let release = updates.available {
                UpdateLine(tag: UpdateNotifier.display(release.tag)) { updates.presentUpdate() }
                    .padding(.bottom, ui(Space.xs))
            }
            if model.legacyDaemon || model.relocating {
                LegacyDaemonLine(relocating: model.relocating) { model.moveToNewLocation() }
                    .padding(.bottom, ui(Space.xs))
            }
            if !model.migrationPending.isEmpty {
                NoticeLine(color: TermAppearance.warning, title: "데이터 옮기기 일부 실패", detail: "다음 실행 때 다시 시도합니다",
                           help: DataLocation.pendingNoticeDetail(model.migrationPending, legacy: DataLocation.legacyRoot(),
                                                                  logPath: Self.logPath))
                    .padding(.bottom, ui(Space.xs))
            }
            if let error = model.lastError {
                Text(error).foregroundStyle(Color(TermAppearance.statusAttention))
            }
            if let claude = usage.claude { UsageLineView(line: claude) }
            if let codex = usage.codex { UsageLineView(line: codex) }
            // 이름은 시스템 글꼴, 크기(숫자)는 고정폭
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("앱 ")
                Text(Memory.format(model.appFootprint)).uiFont(TypeSize.caption)
                Text(" · 데몬 ")
                Text(Memory.format(model.daemonFootprint)).uiFont(TypeSize.caption)
            }
            .lineLimit(1)
            HStack(alignment: .center, spacing: ui(Space.sm)) {
                Text(Self.versionLabel)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: ui(Space.xs))
                SettingsButton(warning: launch.danger(.claude) ?? launch.danger(.codex)) { model.openSettings() }
            }
            daemonLine
        }
        .uiTextFont(TypeSize.caption)
        .foregroundStyle(Color(TermAppearance.textSecondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ui(Space.md))
        .padding(.vertical, ui(Space.md))
        .background(Color(TermAppearance.chrome))
        .overlay(alignment: .top) { Rectangle().fill(Color(TermAppearance.border).opacity(0.5)).frame(height: 1) }
        .environment(\.uiScale, ui)
    }

    private static var logPath: String { TermPaths.home.appendingPathComponent("daemon.log").path }

    /// 맨 아래 데몬 연결 줄: 평소엔 흐리게 한 줄, 붙는 중·실패·세션 유지 제한은 색 점과 함께 눈에 띄게
    @ViewBuilder private var daemonLine: some View {
        if model.connected {
            if model.link.limited {
                NoticeLine(color: TermAppearance.warning, title: "세션 유지 제한", detail: "앱을 강제 종료하면 세션이 끝날 수 있음",
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
            NoticeLine(color: TermAppearance.statusAttention, title: "세션 데몬에 연결하지 못함", detail: "잠시 뒤 다시 시도합니다",
                       help: "\(message) (\(model.link.failures)번째 실패)\n새 화면을 열면 바로 다시 시도합니다.\n기록: \(Self.logPath)")
        } else {
            NoticeLine(color: TermAppearance.textSecondary, title: model.connectionStatusText ?? "세션 데몬 연결 중…", detail: nil,
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
        HStack(alignment: .firstTextBaseline, spacing: ui(Space.sm)) {
            Circle().fill(Color(color)).frame(width: ui(6), height: ui(6))
            VStack(alignment: .leading, spacing: ui(1)) {
                Text(title)
                    .uiTextFont(TypeSize.secondary, weight: .semibold)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                if let detail {
                    Text(detail)
                        .uiTextFont(TypeSize.caption)
                        .foregroundStyle(Color(TermAppearance.textSecondary))
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

/// 상태 줄 오른쪽 "설정"(⌘,). 새 세션 기본 옵션이 위험하면 빨간 경고 표시를 덧붙인다.
private struct SettingsButton: View {
    let warning: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(Space.xs)) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(TermAppearance.warning))
                        .accessibilityLabel("주의")
                }
                Image(systemName: "gearshape")
                Text("설정")
            }
            .uiTextFont(TypeSize.secondary)
            .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textSecondary))
            .padding(.horizontal, ui(Space.sm))
            .frame(minHeight: ui(Space.xxl))
            .background(RoundedRectangle(cornerRadius: ui(6)).fill(Color(TermAppearance.chromeRaised)).opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
            .animation(Motion.ease(Motion.fast), value: hovering)
        }
        .buttonStyle(SidebarPressStyle())
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
        VStack(alignment: .leading, spacing: ui(Space.sm)) {
            HStack(alignment: .firstTextBaseline, spacing: ui(Space.sm)) {
                Circle().fill(Color(TermAppearance.warning)).frame(width: ui(6), height: ui(6))
                Text(relocating ? "새 위치로 옮기는 중…" : "이전 데몬에서 실행 중 — 재시작(또는 재부팅) 시 새 위치로 옮깁니다")
                    .uiTextFont(TypeSize.secondary)
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !relocating {
                Button("지금 옮기기…", action: action)
                    .buttonStyle(NoticeButtonStyle(prominent: false))
                    .help("예전 데몬을 끄고 데이터를 새 위치로 옮깁니다. 열린 셸·claude 가 멈추고, claude·codex 화면은 탭을 열면 되살아납니다.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 상태 줄 맨 위 "새 버전 v0.x.y — 업데이트"(중립 알림: 갱신 기호 + 주 글자색, 누르면 업데이트 방법. 강조색은 쓰지 않는다)
private struct UpdateLine: View {
    let tag: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var ui

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(Space.sm)) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: ui(TypeSize.secondary), weight: .semibold))
                    .foregroundStyle(Color(TermAppearance.textSecondary))
                Text("새 버전 \(tag) — 업데이트")
                    .uiTextFont(TypeSize.secondary, weight: .semibold)
                    .underline(hovering)
            }
            .foregroundStyle(Color(TermAppearance.textPrimary))
            .padding(.horizontal, ui(Space.sm))
            .padding(.vertical, ui(Space.xs))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ui(6)).fill(Color(TermAppearance.chromeRaised)).opacity(hovering ? 1 : 0.6))
            .contentShape(Rectangle())
            .animation(Motion.ease(Motion.fast), value: hovering)
        }
        .buttonStyle(SidebarPressStyle())
        .onHover { hovering = $0 }
        .help("업데이트 명령과 릴리스 페이지 보기")
    }
}
