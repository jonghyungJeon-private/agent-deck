import Foundation

/// 폴더가 속한 git 저장소·작업 트리. git 을 실행하지 않고 .git 파일만 읽는다(목록을 2초마다 새로 고치므로 가볍게).
public struct GitLocation: Equatable, Hashable {
    /// 저장소 본래 작업 폴더(메인 worktree). 목록에서 묶는 기준.
    public var repoRoot: String
    /// 이 폴더가 들어 있는 작업 트리(메인이면 repoRoot 와 같다)
    public var worktreeRoot: String
    /// 공용 .git 폴더
    public var commonDir: String

    public init(repoRoot: String, worktreeRoot: String, commonDir: String) {
        self.repoRoot = repoRoot
        self.worktreeRoot = worktreeRoot
        self.commonDir = commonDir
    }
}

public struct Worktree: Equatable, Hashable {
    public var path: String
    /// 브랜치 이름. 브랜치가 아니면(detached) 커밋 앞 7자리.
    public var branch: String?
    public var isMain: Bool

    public var name: String { (path as NSString).lastPathComponent }
    /// claude 가 만든 작업 트리(--worktree, EnterWorktree 는 .claude/worktrees/ 아래에 만든다)
    public var isClaude: Bool { path.contains("/.claude/worktrees/") }
}

public enum GitWorktrees {
    /// path 에서 위로 올라가며 .git 을 찾는다
    public static func locate(_ path: String) -> GitLocation? {
        let fm = FileManager.default
        var dir = (path as NSString).standardizingPath
        while !dir.isEmpty {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue {
                    return GitLocation(repoRoot: dir, worktreeRoot: dir, commonDir: dotGit)
                }
                // 작업 트리(또는 하위 모듈): ".git" 파일에 "gitdir: <경로>"
                guard let gitDir = gitDirFromFile(dotGit, base: dir) else { return nil }
                let commonFile = (gitDir as NSString).appendingPathComponent("commondir")
                guard let common = read(commonFile) else {
                    // 하위 모듈 등: 따로인 저장소로 본다
                    return GitLocation(repoRoot: dir, worktreeRoot: dir, commonDir: gitDir)
                }
                let commonDir = resolve(common, base: gitDir)
                return GitLocation(repoRoot: repoRoot(commonDir: commonDir), worktreeRoot: dir, commonDir: commonDir)
            }
            if dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// 저장소의 작업 트리 목록. 메인이 맨 앞, 나머지는 폴더 이름순. 폴더가 사라진 것은 뺀다.
    public static func list(_ location: GitLocation) -> [Worktree] {
        let fm = FileManager.default
        let result = [Worktree(path: location.repoRoot,
                               branch: branch(head: (location.commonDir as NSString).appendingPathComponent("HEAD")),
                               isMain: true)]
        let entries = (location.commonDir as NSString).appendingPathComponent("worktrees")
        var others: [Worktree] = []
        for name in (try? fm.contentsOfDirectory(atPath: entries)) ?? [] {
            let entry = (entries as NSString).appendingPathComponent(name)
            // gitdir 파일: "<작업 트리>/.git" 의 경로
            guard let gitFile = read((entry as NSString).appendingPathComponent("gitdir")) else { continue }
            let path = (resolve(gitFile, base: entry) as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: path) else { continue }
            others.append(Worktree(path: path, branch: branch(head: (entry as NSString).appendingPathComponent("HEAD")),
                                   isMain: false))
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result + others
    }

    /// 작업 트리 맨 위 폴더의 git 폴더(메인은 "<폴더>/.git", 작업 트리는 ".git" 파일이 가리키는 곳)
    public static func gitDir(worktreeRoot root: String) -> String? {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? dotGit : gitDirFromFile(dotGit, base: root)
    }

    /// 작업 트리의 지금 브랜치(detached 면 커밋 앞 7자리)
    public static func branch(worktreeRoot root: String) -> String? {
        gitDir(worktreeRoot: root).flatMap { branch(head: ($0 as NSString).appendingPathComponent("HEAD")) }
    }

    static func repoRoot(commonDir: String) -> String {
        (commonDir as NSString).lastPathComponent == ".git" ? (commonDir as NSString).deletingLastPathComponent : commonDir
    }

    static func gitDirFromFile(_ file: String, base: String) -> String? {
        guard let text = read(file), text.hasPrefix("gitdir:") else { return nil }
        return resolve(String(text.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces), base: base)
    }

    static func branch(head: String) -> String? {
        guard let text = read(head) else { return nil }
        if text.hasPrefix("ref:") {
            let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return String(text.prefix(7))
    }

    static func resolve(_ path: String, base: String) -> String {
        let full = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 * 1024,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
