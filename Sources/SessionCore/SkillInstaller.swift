import Foundation

/// 에이전트 스킬(폴더 하나에 SKILL.md)을 Claude Code(`<설정 폴더>/skills`)·Codex(`~/.agents/skills`)에 넣고 뺀다.
/// 이 앱이 넣은 폴더에는 표식 파일(`.agentdeck`)을 두고, 그 폴더만 고치거나 지운다.
/// 사용자가 직접 둔 것(심볼릭 링크·표식 없는 폴더 — 예: abx 개발용 `scripts/install.sh` 의 링크)은 건드리지 않는다.
public struct SkillInstaller {
    public static let marker = ".agentdeck"

    public let skillsDir: URL
    public let name: String

    public init(skillsDir: URL, name: String) {
        self.skillsDir = skillsDir
        self.name = name
    }

    public var skillDir: URL { skillsDir.appendingPathComponent(name, isDirectory: true) }
    var skillFile: URL { skillDir.appendingPathComponent("SKILL.md") }
    var markerFile: URL { skillDir.appendingPathComponent(Self.marker) }

    public enum Status: Equatable {
        case notInstalled
        /// 이 앱이 넣었고 내용이 같다
        case installed
        /// 이 앱이 넣었지만 내용이 다르다(abx 가 바뀜)
        case outdated
        /// 사용자가 직접 둔 것(링크·표식 없는 폴더). 있는 그대로 쓴다.
        case userManaged
    }

    public enum InstallerError: LocalizedError {
        case userManaged(String)

        public var errorDescription: String? {
            switch self {
            case .userManaged(let path): return "\(path) 는 직접 둔 스킬이라 고치지 않습니다"
            }
        }
    }

    public func status(content: String) -> Status {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: skillDir.path)) != nil else { return .notInstalled } // 깨진 링크도 "있음"
        guard ours else { return .userManaged }
        let installed = try? String(contentsOf: skillFile, encoding: .utf8)
        return installed == content ? .installed : .outdated
    }

    /// 이 앱이 넣은 폴더인가(링크가 아닌 진짜 폴더에 표식이 있어야)
    public var ours: Bool {
        let fm = FileManager.default
        guard let type = (try? fm.attributesOfItem(atPath: skillDir.path))?[.type] as? FileAttributeType,
              type == .typeDirectory else { return false }
        return fm.fileExists(atPath: markerFile.path)
    }

    /// 넣거나(없을 때) 내용을 바꾼다(이 앱이 넣은 것일 때). 사용자가 둔 것이면 오류.
    /// 다 쓴 새 폴더를 먼저 만들고, 바꿀 때는 예전 것을 옆으로 옮겨(이 앱 것인지 다시 보고) 새 것을 놓는다 —
    /// 반쯤 쓴 스킬이 보이지 않고, 링크로 바뀌었어도 링크 대상을 덮어쓰지 않고, 놓기에 실패하면 예전 것을 되돌린다.
    public func install(content: String) throws {
        let fm = FileManager.default
        let current = status(content: content)
        switch current {
        case .installed: return
        case .userManaged: throw InstallerError.userManaged((skillDir.path as NSString).abbreviatingWithTildeInPath)
        case .outdated, .notInstalled: break
        }
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let staging = skillsDir.appendingPathComponent(".\(name).agentdeck-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) } // 놓았으면 이미 없다
        try Data(content.utf8).write(to: staging.appendingPathComponent("SKILL.md"))
        try Data("AgentDeck 이 넣은 스킬입니다. 앱 메뉴의 \"브라우저 스킬 연결 해제\"로 뺄 수 있습니다.\n".utf8)
            .write(to: staging.appendingPathComponent(Self.marker))
        var old: URL?
        if current == .outdated {
            guard let aside = try moveAside() else {
                throw InstallerError.userManaged((skillDir.path as NSString).abbreviatingWithTildeInPath)
            }
            old = aside
        }
        do {
            try fm.moveItem(at: staging, to: skillDir) // 그사이 누가 놓았으면 실패한다(덮어쓰지 않는다)
        } catch {
            if let old { try? fm.moveItem(at: old, to: skillDir) }
            throw error
        }
        if let old { try? fm.removeItem(at: old) }
    }

    /// 이 앱이 넣은 것만 지운다. 지웠으면 true.
    @discardableResult
    public func uninstall() throws -> Bool {
        guard let aside = try moveAside() else { return false }
        do {
            try FileManager.default.removeItem(at: aside)
        } catch {
            try? FileManager.default.moveItem(at: aside, to: skillDir) // 못 지웠으면 제자리로(숨은 폴더만 남지 않게)
            throw error
        }
        return true
    }

    /// 이 앱이 넣은 폴더를 옆 이름으로 옮기고 그 자리를 돌려준다(아니면 nil, 건드리지 않음).
    /// 이름 바꾸기는 링크면 링크 자체를 옮기므로, 옮긴 것이 이 앱 것인지 다시 본다 —
    /// 확인과 옮기기 사이에 사용자 것으로 바뀌었으면 제자리로 돌려놓는다.
    private func moveAside() throws -> URL? {
        guard ours else { return nil }
        let fm = FileManager.default
        let aside = skillsDir.appendingPathComponent(".\(name).agentdeck-old-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: skillDir, to: aside)
        guard SkillInstaller(skillsDir: skillsDir, name: aside.lastPathComponent).ours else {
            try? fm.moveItem(at: aside, to: skillDir)
            return nil
        }
        return aside
    }
}

public extension SkillInstaller {
    /// Claude Code 의 사용자 스킬 폴더(CLAUDE_CONFIG_DIR 를 따른다)
    static func claude(name: String, claudeDir: URL = Paths.claudeDir) -> SkillInstaller {
        SkillInstaller(skillsDir: claudeDir.appendingPathComponent("skills", isDirectory: true), name: name)
    }

    /// Codex 의 사용자 스킬 폴더(`~/.agents/skills`)
    static func codex(name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SkillInstaller {
        SkillInstaller(skillsDir: home.appendingPathComponent(".agents/skills", isDirectory: true), name: name)
    }
}
