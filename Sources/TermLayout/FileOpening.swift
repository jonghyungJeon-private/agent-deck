import Foundation

/// 파일 트리에서 파일을 연 결과: 포커스할 화면, 새로 만든 편집기, 닫은 편집기(바꿔 쓴 미리보기 — 문서를 닫아야 한다)
public struct FileOpenResult: Equatable {
    public var focused: String?
    public var created: [String] = []
    public var closed: [String] = []

    public init(focused: String? = nil, created: [String] = [], closed: [String] = []) {
        self.focused = focused
        self.created = created
        self.closed = closed
    }
}

/// 파일 트리에서 파일 열기(배치만 정한다 — 문서·뷰는 앱이 만든다).
///
/// 하나 열기(두 번 클릭·Enter) = 미리보기:
/// 1. 이미 열린 파일이면 그 화면으로 간다(다른 탭이면 그 탭으로). 새로 열지 않는다.
/// 2. 지금 탭에 미리보기 화면이 있으면(지금 화면이 미리보기여도) 그 자리를 이 파일로 바꾼다.
/// 3. 없으면 지금 화면 오른쪽을 나눠 미리보기 화면을 만든다(탭이 없으면 새 탭).
/// 미리보기는 탭에 하나뿐이고, 고치거나 고정하면 보통 화면이 되어 다음 파일은 새 미리보기로 열린다.
///
/// 여러 개 열기(여러 줄 고르고 Enter·두 번 클릭·"열기") = 고정 화면:
/// - 4개까지: 지금 화면 옆 편집기 칸에 위아래로 쌓는다. 미리보기 화면이 있으면 그 자리에, 없으면 지금 화면 오른쪽에.
/// - 그보다 많으면(앱이 묻고) 새 탭 하나에 격자로, 12개까지.
/// 이미 열린 파일은 다시 열지 않는다.
extension Workspace {
    public static let maxStackedFiles = 4
    public static let maxGridFiles = 12

    /// 탭의 미리보기 화면
    public func previewPane(inTab index: Int) -> String? {
        guard tabs.indices.contains(index) else { return nil }
        return tabs[index].root.panes.first { editors[$0]?.isPreview == true }
    }

    /// 미리보기를 보통 화면으로(고침·고정). 바뀌었으면 true.
    @discardableResult
    public mutating func pin(editor id: String) -> Bool {
        guard editors[id]?.isPreview == true else { return false }
        editors[id]?.preview = nil
        return true
    }

    /// 이미 열린 화면으로 가기(그 탭을 고르고 포커스)
    private mutating func focusExisting(_ pane: String) -> FileOpenResult? {
        guard let index = tabIndex(containing: pane) else { return nil }
        selected = tabs[index].id
        if tabs[index].focused != pane {
            tabs[index].focused = pane
            tabs[index].zoomed = false
        }
        return FileOpenResult(focused: pane)
    }

    /// 하나 열기(미리보기)
    public mutating func openPreview(path: String, newId: () -> String) -> FileOpenResult {
        if let existing = editorPane(path: path), let result = focusExisting(existing) { return result }
        let id = newId()
        editors[id] = EditorRecipe(path: path, preview: true)
        guard let index = selectedIndex else {
            let tab = TabState(root: .pane(id), focused: id)
            tabs.append(tab)
            selected = tab.id
            return FileOpenResult(focused: id, created: [id])
        }
        var tab = tabs[index]
        var closed: [String] = []
        if let preview = previewPane(inTab: index) {
            tab.root = tab.root.replacing(preview, with: .pane(id))
            closed = [preview]
        } else {
            tab.root = tab.root.splitting(tab.focused, with: id, axis: .horizontal)
        }
        tab.focused = id
        tab.zoomed = false
        tabs[index] = tab
        for old in closed { editors[old] = nil }
        return FileOpenResult(focused: id, created: [id], closed: closed)
    }

    /// 여러 개를 지금 화면 옆 칸에 위아래로(고정 화면, maxStackedFiles 개까지)
    public mutating func openStacked(paths: [String], newId: () -> String) -> FileOpenResult {
        let (fresh, existing) = partition(paths, limit: Self.maxStackedFiles)
        guard !fresh.isEmpty else { return existing.first.flatMap { focusExisting($0) } ?? FileOpenResult() }
        guard let index = selectedIndex else { return openGrid(paths: fresh, newId: newId) }
        let ids = fresh.map { path -> String in
            let id = newId()
            editors[id] = EditorRecipe(path: path)
            return id
        }
        guard let column = SplitNode.stack(ids.map(SplitNode.pane), axis: .vertical) else { return FileOpenResult() }
        var tab = tabs[index]
        var closed: [String] = []
        if let preview = previewPane(inTab: index) {
            tab.root = tab.root.replacing(preview, with: column)
            closed = [preview]
        } else {
            tab.root = tab.root.inserting(column, at: tab.focused, toward: .right)
        }
        tab.focused = ids[0]
        tab.zoomed = false
        tabs[index] = tab
        for old in closed { editors[old] = nil }
        return FileOpenResult(focused: ids[0], created: ids, closed: closed)
    }

    /// 여러 개를 새 탭 하나에 격자로(고정 화면, maxGridFiles 개까지). 지금 탭 바로 뒤에 둔다.
    public mutating func openGrid(paths: [String], newId: () -> String) -> FileOpenResult {
        let (fresh, existing) = partition(paths, limit: Self.maxGridFiles)
        guard !fresh.isEmpty else { return existing.first.flatMap { focusExisting($0) } ?? FileOpenResult() }
        let ids = fresh.map { path -> String in
            let id = newId()
            editors[id] = EditorRecipe(path: path)
            return id
        }
        guard let root = SplitNode.grid(ids) else { return FileOpenResult() }
        let tab = TabState(root: root, focused: ids[0])
        tabs.insert(tab, at: selectedIndex.map { $0 + 1 } ?? tabs.count)
        selected = tab.id
        return FileOpenResult(focused: ids[0], created: ids)
    }

    /// 겹친 경로를 빼고 새로 열 것(limit 개까지)과 이미 열린 화면으로 나눈다
    private func partition(_ paths: [String], limit: Int) -> (fresh: [String], existing: [String]) {
        var seen: Set<String> = []
        var fresh: [String] = []
        var existing: [String] = []
        for path in paths where seen.insert(path).inserted {
            if let pane = editorPane(path: path) { existing.append(pane) } else { fresh.append(path) }
        }
        return (Array(fresh.prefix(limit)), existing)
    }
}
