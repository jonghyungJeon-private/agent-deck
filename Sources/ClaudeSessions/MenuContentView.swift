import SessionCore
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: SessionsModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.hookStatus == .notInstalled { connectBanner }
            if let message = model.message { messageBanner(message) }
            if model.running.count + model.stopped.count > 8 {
                TextField("검색", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    runningSection(filtered(model.running))
                    stoppedSection(filtered(model.stopped))
                }
                .padding(.vertical, 6)
            }
            .frame(height: 480)
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear {
            model.refreshHookStatus()
            model.refresh()
        }
    }

    private var header: some View {
        HStack {
            Text("Claude Sessions").font(.headline)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("새로 고침")
        }
        .padding(10)
    }

    private var connectBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code 와 아직 연결되지 않았습니다").font(.subheadline.bold())
            Text("연결하면 ~/.claude/settings.json 에 세션 기록용 hook 이 추가됩니다(기존 설정은 백업 후 유지).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Claude Code 연결") { model.connectClaude() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
    }

    private func messageBanner(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }

    private func filtered(_ items: [SessionItem]) -> [SessionItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            [$0.title, $0.location, $0.lastPrompt ?? "", $0.record.cwd].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    struct Group: Identifiable {
        var id: String
        var name: String
        var items: [SessionItem]
    }

    /// 순서는 목록 순서(최근 활동 순)를 따른다: 가장 최근 세션이 있는 묶음이 위로.
    private func grouped(_ items: [SessionItem], by key: (SessionItem) -> (id: String, name: String)) -> [Group] {
        var groups: [Group] = []
        for item in items {
            let k = key(item)
            if let index = groups.firstIndex(where: { $0.id == k.id }) {
                groups[index].items.append(item)
            } else {
                groups.append(Group(id: k.id, name: k.name, items: [item]))
            }
        }
        return groups
    }

    private func byProject(_ items: [SessionItem]) -> [Group] {
        grouped(items) { ($0.projectPath, $0.projectName) }
    }

    @ViewBuilder
    private func runningSection(_ items: [SessionItem]) -> some View {
        sectionHeader("실행 중", count: items.count)
        if items.isEmpty { emptyText("열려 있는 세션이 없습니다") }
        ForEach(grouped(items) { ($0.terminalName, $0.terminalName) }) { terminal in
            Label("\(terminal.name) (\(terminal.items.count))", systemImage: "macwindow")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            projectGroups(byProject(terminal.items), indent: 12)
        }
    }

    @ViewBuilder
    private func stoppedSection(_ items: [SessionItem]) -> some View {
        sectionHeader("꺼짐 · 클릭해서 이어 열기", count: items.count)
            .padding(.top, 6)
        if items.isEmpty { emptyText("이어 열 세션이 없습니다") }
        projectGroups(byProject(items), indent: 0)
    }

    @ViewBuilder
    private func projectGroups(_ groups: [Group], indent: CGFloat) -> some View {
        ForEach(groups) { group in
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(group.name)
                Text("\(group.items.count)").foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 12 + indent)
            .padding(.top, 4)
            .help(group.id)
            ForEach(group.items) { item in
                SessionRow(item: item, indent: indent + 12)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(.caption.bold())
            .foregroundStyle(.primary.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    /// 꺼진 세션이 돌던 터미널들의 기록된 배치(예: "iTerm2 창 1 · 탭 2 · 화면 3 (16:20)")
    private var layoutSummary: String? {
        let sources = Set(model.stopped.map { SessionActions.sourceTerminal(of: $0.record).id })
        let parts = TerminalRegistry.all.compactMap { launcher -> String? in
            guard sources.contains(launcher.id), let layout = model.layouts[launcher.id] else { return nil }
            let tabs = layout.windows.reduce(0) { $0 + $1.tabs.count }
            let panes = layout.windows.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.terminals.count } }
            let time = layout.capturedAt.formatted(date: .omitted, time: .shortened)
            return "\(launcher.displayName) 창 \(layout.windows.count) · 탭 \(tabs) · 화면 \(panes) (\(time))"
        }
        return parts.isEmpty ? nil : "기록된 배치: " + parts.joined(separator: " / ")
    }

    private var openableStopped: [SessionItem] { model.stopped.filter { !$0.isOpening } }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    model.resumeAllStopped()
                } label: {
                    Label(model.isRestoring ? "여는 중…" : "모두 열기 (배치 유지)", systemImage: "rectangle.split.2x1")
                }
                .disabled(openableStopped.isEmpty || model.isRestoring)
                .help("꺼진 세션을 기록된 창·탭·분할 배치대로 엽니다. Ghostty 가 되살린 빈 창이 있으면 그 자리에 엽니다.")
                if model.stopped.isEmpty {
                    Text(model.running.isEmpty ? "열 세션이 없습니다" : "꺼진 세션이 없습니다 — 모두 실행 중")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if openableStopped.isEmpty {
                    Text("꺼진 세션을 여는 중입니다").font(.caption2).foregroundStyle(.tertiary)
                } else if let layoutSummary {
                    Text(layoutSummary).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                AppDelegate.shared?.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("설정")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("종료")
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

struct SessionRow: View {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    @EnvironmentObject private var model: SessionsModel
    let item: SessionItem
    var indent: CGFloat = 0
    @State private var hovering = false

    /// 묶음 이름에 저장소가 나오므로 행에는 하위 폴더·브랜치만
    private var detail: String? {
        let parts = [item.subpath, item.branch.map { "@ \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.isRunning ? Color.green : item.isOpening ? Color.orange : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title).lineLimit(1)
                    if item.isOpening { Text("여는 중…").font(.caption).foregroundStyle(.orange) }
                }
                HStack(spacing: 4) {
                    if let detail {
                        Text(detail)
                        Text("·")
                    }
                    // style: .relative 는 1초마다 목록을 다시 그려서 쓰지 않는다(5초마다 새로 고칠 때 갱신)
                    Text(Self.relative.localizedString(for: item.lastActivity, relativeTo: model.lastRefresh))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let prompt = item.lastPrompt, prompt != item.title {
                    Text("마지막 요청: \(prompt)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if hovering && !item.isRunning {
                Button {
                    model.forget(item)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("목록에서 지우기")
            }
        }
        .padding(.leading, 12 + indent)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if !item.isOpening { model.activate(item) }
        }
        .help(item.isRunning ? "열려 있는 탭으로 이동"
              : item.isOpening ? "여는 중입니다. claude 가 뜨면 실행 중으로 옮겨집니다."
              : "\(SessionActions.targetTerminal(of: item.record).displayName) 새 탭에서 이어 열기\n\(item.record.cwd)")
        .contextMenu {
            Button("폴더 경로 복사") { copy(item.record.cwd) }
            Button("세션 ID 복사") { copy(item.id) }
            if !item.isRunning && !item.isOpening {
                Divider()
                Button("이어 열기") { model.resume(item, skipPermissions: false) }
                Button("권한 확인 없이 이어 열기 (--dangerously-skip-permissions)") { model.resume(item, skipPermissions: true) }
                Divider()
                Button("목록에서 지우기") { model.forget(item) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
