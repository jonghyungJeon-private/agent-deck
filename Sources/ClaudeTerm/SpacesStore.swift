import AppKit
import Foundation
import TermLayout
import TermWire

/// spaces 의 접기·순서(SpacesState)를 들고 `term/spaces.json` 에 쓴다. 사람이 누르거나 끌 때만 바뀌므로 바로 쓴다(작은 파일).
/// 끄는 중인 줄(drag)은 저장하지 않는다 — 시험 명령으로도 그려 볼 수 있게 뷰 밖에 둔다.
final class SpacesStore: ObservableObject {
    @Published private(set) var state: SpacesState
    @Published var drag: SpacesDrag?

    static var url: URL { TermPaths.home.appendingPathComponent("spaces.json") }

    init() {
        state = SpacesState.load(from: Self.url)
    }

    private func change(_ update: (inout SpacesState) -> Void) {
        var next = state
        update(&next)
        guard next != state else { return }
        state = next
        guard let data = next.data() else { return }
        try? FileManager.default.createDirectory(at: TermPaths.home, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    func toggle(_ key: String) { change { $0.toggle(key) } }

    /// 모두 접기: 묶음과 그 안의 작업 트리까지(펼치면 작업 트리도 접힌 채로 보인다)
    func collapseAll(_ groups: [FolderGroup]) {
        change { $0.collapseAll(Self.collapsibleKeys(groups)) }
    }

    func expandAll() { change { $0.expandAll() } }

    static func collapsibleKeys(_ groups: [FolderGroup]) -> [String] {
        groups.flatMap { group in
            [SpacesState.groupKey(group.path)] + group.sections.filter { !$0.isMain }.map { SpacesState.worktreeKey($0.path) }
        }
    }

    /// 묶음 순서: 보이는 순서 기준으로 id 를 target 자리로
    func moveGroup(_ id: String, onto target: String, groups: [FolderGroup]) {
        let displayed = SpacesOrder.apply(groups, order: state.groupOrder, id: \.path).map(\.path)
        change { $0.moveGroup(id, onto: target, displayed: displayed) }
    }

    /// 세션 순서: 같은 작업 트리 안에서만(다른 칸으로 놓으면 무시)
    func moveSession(_ id: String, onto target: String, groups: [FolderGroup]) {
        guard let section = groups.lazy.flatMap(\.sections).first(where: { section in
            section.rows.contains { $0.id == id } && section.rows.contains { $0.id == target }
        }) else { return }
        let siblings = SpacesOrder.apply(section.rows, order: state.sessionOrder, id: \.id).map(\.id)
        let live = Set(groups.flatMap { $0.sections.flatMap { $0.rows.map(\.id) } })
        change { $0.moveSession(id, onto: target, siblings: siblings, live: live) }
    }

    /// 끌어 놓기 마무리(놓은 곳이 맞으면 옮기고, 끄는 상태는 지운다)
    func finishDrag(groups: [FolderGroup]) {
        guard let drag else { return }
        self.drag = nil
        guard let target = drag.target else { return }
        switch drag.kind {
        case .group: moveGroup(drag.id, onto: target, groups: groups)
        case .session: moveSession(drag.id, onto: target, groups: groups)
        }
    }

    // MARK: - 시험 명령

    /// spaces | spaces-toggle <g:경로|w:경로> | spaces-collapse-all | spaces-expand-all
    /// spaces-move-group <경로>|<대상 경로> | spaces-move-session <화면 ID>|<대상 화면 ID>
    /// spaces-drag <group|session> <ID>|<대상 ID>(끄는 모습만 그린다) | spaces-drag-end
    /// 화면 ID 는 앞부분만 써도 된다(`rows` 처럼 4글자).
    func debug(_ command: String, _ argument: String, groups: [FolderGroup]) -> Bool {
        let pair = argument.split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        let panes = groups.flatMap { $0.sections.flatMap { $0.rows.map(\.id) } }
        func pane(_ prefix: String) -> String { panes.first { $0.hasPrefix(prefix) } ?? prefix }
        switch command {
        case "spaces":
            for item in SidebarItem.flatten(groups, spaces: state) { print("spaces " + item.debugLine) }
            print("spaces state " + (state.data().flatMap { String(data: $0, encoding: .utf8) }?
                .replacingOccurrences(of: "\n", with: " ") ?? "-"))
            fflush(stdout)
        case "spaces-toggle": toggle(argument)
        case "spaces-collapse-all": collapseAll(groups)
        case "spaces-expand-all": expandAll()
        case "spaces-move-group":
            if pair.count == 2 { moveGroup(pair[0], onto: pair[1], groups: groups) }
        case "spaces-move-session":
            if pair.count == 2 { moveSession(pane(pair[0]), onto: pane(pair[1]), groups: groups) }
        case "spaces-drag":
            let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, let kind = SpacesDrag.Kind(rawValue: words[0]) else { return true }
            let ids = words[1].split(separator: "|", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            let id = kind == .session ? pane(ids[0]) : ids[0]
            let items = SidebarItem.flatten(groups, spaces: state)
            var drag = SpacesDrag(kind: kind, id: id, section: items.lazy.compactMap { item -> String? in
                if case .session(let row, _, _, let section) = item, row.id == id { return section }
                return nil
            }.first)
            if ids.count == 2 {
                let target = kind == .session ? pane(ids[1]) : ids[1]
                drag.target = target
                drag.after = SpacesOrder.insertsAfter(drag.siblings(in: items), id, onto: target)
            }
            self.drag = drag
        case "spaces-drag-end": drag = nil
        default: return false
        }
        return true
    }
}

/// 끄는 중인 줄: 묶음(경로) 또는 세션(화면 ID). target 은 놓을 자리, after 면 그 아래에 줄을 긋는다.
struct SpacesDrag: Equatable {
    enum Kind: String { case group, session }
    var kind: Kind
    var id: String
    /// 세션을 끌 때 그 세션의 칸(작업 트리 경로) — 이 칸 안에서만 놓을 수 있다
    var section: String?
    var target: String?
    var after = false

    /// 이 끌기로 순서를 바꿀 수 있는 줄들(보이는 순서): 묶음이면 모든 묶음, 세션이면 같은 칸의 세션
    func siblings(in items: [SidebarItem]) -> [String] {
        switch kind {
        case .group:
            return items.compactMap { if case .group(let group, _, _) = $0 { return group.path }; return nil }
        case .session:
            return items.compactMap { item in
                if case .session(let row, _, _, let s) = item, s == section { return row.id }
                return nil
            }
        }
    }

    /// 이 줄 위로 끌고 왔을 때 놓을 자리(없으면 놓을 수 없는 줄)
    func target(for item: SidebarItem) -> String? {
        switch kind {
        case .group:
            return item.groupPath == id ? nil : item.groupPath
        case .session:
            guard case .session(let row, _, _, let s) = item, s == section, row.id != id else { return nil }
            return row.id
        }
    }
}
