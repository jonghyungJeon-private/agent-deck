import AppKit
import SwiftUI
import TermWire

private extension Color {
    init(_ color: NSColor) { self.init(nsColor: color) }
}

/// 왼쪽 목록(herdr 처럼): 폴더(git 저장소)별 묶음 → 작업 트리(worktree) → 그 안의 세션.
/// 어두운 바탕에 고정폭 글꼴, 색은 상태와 포커스에만 쓴다.
struct SidebarView: View {
    @ObservedObject var model: TermModel
    /// 펼쳐 본 하위 에이전트(마지막 메시지를 보여 준다)
    @State private var expandedAgent: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.groups.isEmpty {
                        Text(model.connected ? "열린 세션이 없습니다.\n위 + claude 로 시작하세요." : "데몬에 연결 중…")
                            .font(Font(TermAppearance.uiFont(11)))
                            .foregroundStyle(Color(TermAppearance.textDim))
                            .padding(14)
                    }
                    // 묶음·작업 트리·세션을 한 줄짜리 목록으로 펼쳐 그린다.
                    // ForEach 를 겹쳐 쓰면 안쪽 줄이 바뀐 것을 SwiftUI 가 놓쳐 이름이 늦게 바뀌었다.
                    ForEach(SidebarItem.flatten(model.groups)) { item in
                        switch item {
                        case .group(let group):
                            GroupRowView(group: group, menu: { openMenu(group.path) })
                        case .worktree(let section):
                            WorktreeRowView(section: section)
                                .contextMenu { openMenu(section.path) }
                        case .session(let row, let depth):
                            SessionRowView(row: row, depth: depth,
                                           selected: row.id == model.selectedId,
                                           tabNumber: model.workspace.tabIndex(containing: row.id).map { $0 + 1 })
                                .onTapGesture { model.focus(pane: row.id) }
                                .contextMenu {
                                    Button("이름 바꾸기…") { model.rename(pane: row.id) }
                                    Button("화면 닫기(셸·claude 종료)") { model.close(pane: row.id) }
                                    Divider()
                                    openMenu(row.cwd)
                                }
                        case .agent(let agent, let depth, let owner):
                            AgentRowView(agent: agent, depth: depth, owner: owner, expanded: expandedAgent == agent.id)
                                .onTapGesture {
                                    // 띄운 claude 화면으로 넘어가고, 무엇을 하는지 펼쳐 본다
                                    model.focus(pane: agent.paneId)
                                    expandedAgent = expandedAgent == agent.id ? nil : agent.id
                                }
                        case .gap:
                            Spacer().frame(height: 10)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            hookBanner
            footer
        }
        .frame(minWidth: 220, maxHeight: .infinity)
        .background(Color(TermAppearance.chrome))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("spaces")
                .font(Font(TermAppearance.uiFont(11)))
                .foregroundStyle(Color(TermAppearance.textDim))
            Spacer()
            ChromeButton(label: "+ claude", help: "폴더를 골라 새 탭에서 claude 실행") {
                pickFolder { model.newPane(cwd: $0, command: "claude") }
            }
            ChromeButton(label: "+ 셸", help: "홈 폴더에서 새 셸 탭 (지금 화면 폴더는 ⌘T)") {
                model.newPane(cwd: NSHomeDirectory())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: TerminalHostController.tabBarHeight)
    }

    /// hook 이 없거나 예전 앱 것이면 눈에 띄게 알린다(이름·되살리기·상태 표시가 여기에 달려 있다)
    @ViewBuilder
    private var hookBanner: some View {
        let message: String? = {
            switch model.hookState {
            case .missing: return "Claude Code 와 연결되지 않았습니다. 세션 이름·되살리기·상태 표시에 필요합니다."
            case .legacy: return "예전 ClaudeSessions 앱으로 연결돼 있습니다. ClaudeTerm 으로 옮겨 두면 그 앱을 지워도 됩니다."
            case .error(let detail): return "Claude Code 설정을 읽지 못했습니다: \(detail)"
            default: return nil
            }
        }()
        let canConnect: Bool = {
            if case .error = model.hookState { return false }
            return true
        }()
        if let message {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(Font(TermAppearance.uiFont(11)))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                if canConnect {
                    Button {
                        model.connectHooks()
                    } label: {
                        Text(model.hookState == .legacy ? "ClaudeTerm 으로 옮기기" : "연결하기")
                            .font(Font(TermAppearance.uiFont(11, bold: true)))
                            .foregroundStyle(Color(TermAppearance.chrome))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(TermAppearance.accent)))
                    }
                    .buttonStyle(.plain)
                    .help("~/.claude/settings.json 에 SessionStart·SessionEnd hook 을 넣습니다(바꾸기 전 백업)")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(TermAppearance.accent), lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        if let notice = model.notice {
            Text(notice)
                .font(Font(TermAppearance.uiFont(10)))
                .foregroundStyle(Color(TermAppearance.textDim))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .onTapGesture { model.notice = nil }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = model.lastError {
                Text(error).foregroundStyle(Color(TermAppearance.red))
            }
            Text("앱 \(Memory.format(model.appFootprint)) · 데몬 \(Memory.format(model.daemonFootprint))")
            Text(model.connected ? "앱을 꺼도 세션은 계속 돕니다" : "데몬 연결 끊김")
        }
        .font(Font(TermAppearance.uiFont(10)))
        .foregroundStyle(Color(TermAppearance.textDim))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color(TermAppearance.border).opacity(0.5)).frame(height: 1) }
    }

    /// 폴더·작업 트리에서 새로 열기
    @ViewBuilder
    private func openMenu(_ path: String) -> some View {
        Button("여기서 claude 열기(새 탭)") { model.newPane(cwd: path, command: "claude") }
        Button("여기서 셸 열기(새 탭)") { model.newPane(cwd: path) }
        Button("Finder 에서 보기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    }

    private func pickFolder(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "여기서 claude 실행"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("demo_Project")
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

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Font(TermAppearance.uiFont(11)))
                .foregroundStyle(Color(hovering ? TermAppearance.textPrimary : TermAppearance.textDim))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(hovering ? TermAppearance.chromeRaised : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 상태 점. claude 는 claude 색, 셸은 흐리게.
/// 꺼진 화면은 속이 빈 점
struct StatusDot: View {
    let isClaude: Bool
    var dormant = false

    var body: some View {
        let color = Color(isClaude ? TermAppearance.claudeColor : TermAppearance.textDim.withAlphaComponent(0.6))
        Group {
            if dormant {
                Circle().strokeBorder(color, lineWidth: 1.2)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 7, height: 7)
    }
}

struct GroupRowView<MenuContent: View>: View {
    let group: FolderGroup
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(isClaude: group.sections.contains { $0.rows.contains(where: \.isClaude) })
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(Font(TermAppearance.uiFont(12, bold: true)))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text(group.branch ?? (group.path as NSString).abbreviatingWithTildeInPath)
                    .font(Font(TermAppearance.uiFont(10)))
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                menu()
            } label: {
                Text("+").font(Font(TermAppearance.uiFont(13)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .help("이 폴더에서 새로 열기")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        .help(group.path)
    }
}

struct WorktreeRowView: View {
    let section: WorktreeSection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(section.isClaude ? TermAppearance.claudeColor : TermAppearance.textDim))
            VStack(alignment: .leading, spacing: 1) {
                Text(section.name)
                    .font(Font(TermAppearance.uiFont(11, bold: true)))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                Text(section.branch ?? "")
                    .font(Font(TermAppearance.uiFont(10)))
                    .foregroundStyle(Color(TermAppearance.textDim))
            }
            Spacer(minLength: 4)
            if section.agents.contains(where: \.isRunning) {
                Text("● 작업 중 \(section.agents.filter(\.isRunning).count)")
                    .font(Font(TermAppearance.uiFont(10, bold: true)))
                    .foregroundStyle(Color(TermAppearance.yellow))
            } else if !section.agents.isEmpty {
                Text("최근 작업").font(Font(TermAppearance.uiFont(10))).foregroundStyle(Color(TermAppearance.textDim))
            } else if section.rows.isEmpty {
                Text("세션 없음").font(Font(TermAppearance.uiFont(10))).foregroundStyle(Color(TermAppearance.textDim).opacity(0.7))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 14 + 13)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(section.isClaude ? "claude 가 만든 작업 트리 · \(section.path)" : section.path)
    }
}

struct SessionRowView: View {
    let row: PaneRow
    let depth: Int
    let selected: Bool
    let tabNumber: Int?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(isClaude: row.isClaude, dormant: row.dormant)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(Font(TermAppearance.uiFont(12, bold: selected)))
                    .foregroundStyle(Color(TermAppearance.textPrimary))
                if row.dormant {
                    Text(row.isClaude ? "꺼짐 · 열면 claude 를 이어서 시작" : "꺼짐 · 열면 셸을 다시 시작")
                        .font(Font(TermAppearance.uiFont(10)))
                        .foregroundStyle(Color(TermAppearance.textDim))
                } else {
                HStack(spacing: 0) {
                    Text(row.program)
                        .foregroundStyle(Color(row.isClaude ? TermAppearance.claudeColor : TermAppearance.textDim))
                    // 제목이 이미 폴더 이름이면 같은 말을 되풀이하지 않고 터미널 장치로 구분한다
                    Text(" · \(row.title == row.folder ? (row.pane.tty ?? "") : row.folder)")
                        .foregroundStyle(Color(TermAppearance.textDim))
                }
                .font(Font(TermAppearance.uiFont(10)))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let tabNumber {
                Text("⌘\(tabNumber)")
                    .font(Font(TermAppearance.uiFont(10)))
                    .foregroundStyle(Color(selected ? TermAppearance.accent : TermAppearance.textDim).opacity(0.8))
                    .help("탭 \(tabNumber)에 있음")
            }
        }
        .padding(.leading, 14 + CGFloat(depth) * 15)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(selected ? TermAppearance.chromeRaised : hovering ? TermAppearance.chromeRaised.withAlphaComponent(0.5) : .clear))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color(TermAppearance.accent)).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(row.name)\n\(row.cwd) · \(row.pane.tty ?? "")")
    }
}

/// 왼쪽 목록 한 줄(묶음 머리·작업 트리·세션·묶음 사이 틈)
enum SidebarItem: Identifiable, Equatable {
    case group(FolderGroup)
    case worktree(WorktreeSection)
    case session(PaneRow, depth: Int)
    /// 하위 에이전트(owner: 띄운 claude 화면 이름 — 다른 줄 아래에 있을 때만)
    case agent(SubagentActivity, depth: Int, owner: String?)
    case gap(String)

    var id: String {
        switch self {
        case .group(let group): return "g:" + group.path
        case .worktree(let section): return "w:" + section.path
        case .session(let row, _): return "s:" + row.id
        case .agent(let agent, _, _): return "a:" + agent.sessionId + agent.id
        case .gap(let path): return "gap:" + path
        }
    }

    static func flatten(_ groups: [FolderGroup]) -> [SidebarItem] {
        var items: [SidebarItem] = []
        let owners = Dictionary(groups.flatMap { $0.sections.flatMap(\.rows) }.map { ($0.id, $0.name) },
                                uniquingKeysWith: { first, _ in first })
        for group in groups {
            items.append(.group(group))
            for section in group.sections {
                let depth = section.isMain ? 1 : 2
                if !section.isMain {
                    items.append(.worktree(section))
                    // 이 작업 트리에서 일하는 하위 에이전트(띄운 claude 는 다른 줄에 있으므로 이름을 함께 보인다)
                    items += section.agents.map { .agent($0, depth: depth, owner: owners[$0.paneId]) }
                }
                for row in section.rows {
                    items.append(.session(row, depth: depth))
                    items += row.agents.map { .agent($0, depth: depth + 1, owner: nil) }
                }
            }
            items.append(.gap(group.path))
        }
        return items
    }
}

/// 하위 에이전트 한 줄. 누르면 띄운 claude 화면으로 넘어가고 마지막 메시지를 펼친다.
struct AgentRowView: View {
    let agent: SubagentActivity
    let depth: Int
    let owner: String?
    let expanded: Bool
    @State private var hovering = false

    private var when: String {
        if agent.isRunning { return "작업 중" }
        let minutes = max(1, Int(Date().timeIntervalSince(agent.lastActive) / 60))
        return "\(minutes)분 전"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("↳")
                    .font(Font(TermAppearance.uiFont(11)))
                    .foregroundStyle(Color(TermAppearance.textDim))
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.description)
                        .font(Font(TermAppearance.uiFont(11)))
                        .foregroundStyle(Color(agent.isRunning ? TermAppearance.textPrimary : TermAppearance.textDim))
                    HStack(spacing: 0) {
                        Text(when)
                            .foregroundStyle(Color(agent.isRunning ? TermAppearance.yellow : TermAppearance.textDim))
                        Text([agent.agentType, owner.map { "\($0) 의 하위 에이전트" }].compactMap { $0 }
                            .map { " · " + $0 }.joined())
                            .foregroundStyle(Color(TermAppearance.textDim))
                    }
                    .font(Font(TermAppearance.uiFont(10)))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if expanded {
                Text(agent.lastText ?? "아직 남긴 메시지가 없습니다.")
                    .font(Font(TermAppearance.uiFont(10)))
                    .foregroundStyle(Color(TermAppearance.textPrimary).opacity(0.85))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(TermAppearance.chromeRaised)))
            }
        }
        .padding(.leading, 14 + CGFloat(depth) * 15)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hovering ? TermAppearance.chromeRaised.withAlphaComponent(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("누르면 이 에이전트를 띄운 claude 화면으로 이동하고 마지막 메시지를 펼칩니다\n\(agent.worktreePath ?? "")")
    }
}
