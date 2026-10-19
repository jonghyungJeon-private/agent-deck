import Foundation

/// files 도구가 보이는 루트(프로젝트)
public struct FilesRoot: Equatable, Hashable, Sendable {
    public var path: String
    public var isGit: Bool

    public init(path: String, isGit: Bool) {
        self.path = path
        self.isGit = isGit
    }

    /// 터미널 화면: 작업 트리 맨 위, 저장소가 아니면 그 폴더
    public static func folder(_ directory: String, git: GitLocation?) -> FilesRoot {
        if let git { return FilesRoot(path: git.worktreeRoot, isGit: true) }
        return FilesRoot(path: (directory as NSString).standardizingPath, isGit: false)
    }

    /// 편집기 화면: 지금 보는 루트 안의 파일이면 루트를 그대로 둔다(상위 폴더를 둘러보다 하위 저장소 파일을 열어도
    /// 트리가 그 저장소로 바뀌어 보던 자리를 잃지 않게). 루트 밖이면 그 파일 폴더로 터미널과 같은 규칙.
    public static func editor(file: String, current: FilesRoot?, locate: (String) -> GitLocation?) -> FilesRoot {
        if let current, current.contains(file) { return current }
        let directory = (file as NSString).deletingLastPathComponent
        return folder(directory, git: locate(directory))
    }

    /// 이 루트 안(루트 자신 포함)
    public func contains(_ other: String) -> Bool {
        other == path || other.hasPrefix(path == "/" ? "/" : path + "/")
    }

    /// 루트 기준 상대 경로(루트 자신은 "", 밖이면 nil)
    public func relative(_ other: String) -> String? {
        guard contains(other) else { return nil }
        if other == path { return "" }
        return String(other.dropFirst(path == "/" ? 1 : path.count + 1))
    }
}
