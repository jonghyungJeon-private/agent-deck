import Foundation

/// ~/.claude/settings.json 에 이 앱의 SessionStart / SessionEnd hook 을 넣고 뺀다.
/// 사용자의 다른 설정·hook 은 그대로 두고, 바꾸기 전에 백업을 남긴다.
public struct HookInstaller {
    public static let events = ["SessionStart", "SessionEnd"]
    /// 이 앱이 넣은 hook 인지 알아보는 표식. 실행 파일 경로가 바뀌어도(앱 이동) 찾을 수 있게 끝부분만 본다.
    static let commandSuffix = "ClaudeSessions\" hook"

    public let settingsURL: URL
    public let executablePath: String

    public init(settingsURL: URL = Paths.claudeSettings, executablePath: String) {
        self.settingsURL = settingsURL
        self.executablePath = executablePath
    }

    public enum Status: Equatable {
        case notInstalled
        case installed
        /// 다른 경로(예: 옮기기 전 앱)를 가리키는 hook 이 있다.
        case outdated
    }

    public enum InstallerError: LocalizedError {
        case invalidSettings(String)

        public var errorDescription: String? {
            switch self {
            case .invalidSettings(let detail): return "settings.json 을 읽을 수 없습니다: \(detail)"
            }
        }
    }

    /// hook 은 셸로 실행되므로 경로를 큰따옴표로 감싼다.
    public var command: String {
        let escaped = executablePath.reduce(into: "") { out, ch in
            if "\"\\$`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return "\"\(escaped)\" hook"
    }

    static func isOurs(_ command: String) -> Bool { command.hasSuffix(commandSuffix) }

    /// 지금 settings.json 의 이 앱 hook 이 가리키는 실행 파일들
    public func installedExecutablePaths() throws -> [String] {
        let hooks = try loadSettings()["hooks"] as? [String: Any] ?? [:]
        return Self.events.flatMap { commands(in: hooks[$0]) }.filter(Self.isOurs).compactMap { command in
            guard command.hasPrefix("\""), let end = command.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(command[command.index(after: command.startIndex)..<end]).replacingOccurrences(of: "\\", with: "")
        }
    }

    /// 앱을 옮겨서 기존 hook 이 가리키는 파일이 없어졌을 때만 true.
    /// 다른 위치의 앱(개발용 빌드 등)이 따로 실행 중일 때 서로 settings.json 을 고쳐 쓰지 않게 한다.
    public func needsRepair() throws -> Bool {
        guard try status() == .outdated else { return false }
        let paths = try installedExecutablePaths()
        return !paths.isEmpty && paths.allSatisfy { !FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func status() throws -> Status {
        let settings = try loadSettings()
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var found = 0, current = 0
        for event in Self.events {
            for command in commands(in: hooks[event]) where Self.isOurs(command) {
                found += 1
                if command == self.command { current += 1 }
            }
        }
        if found == 0 { return .notInstalled }
        return current == Self.events.count && found == current ? .installed : .outdated
    }

    /// 이미 있던 이 앱의 hook 은 지우고 현재 경로로 다시 넣는다. 백업 경로를 돌려준다(원본이 없었으면 nil).
    @discardableResult
    public func install() throws -> URL? {
        var settings = try loadSettings()
        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        for event in Self.events {
            var groups = hooks[event] as? [Any] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return try save(settings)
    }

    @discardableResult
    public func uninstall() throws -> URL? {
        var settings = try loadSettings()
        let hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return try save(settings)
    }

    // MARK: -

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallerError.invalidSettings("최상위가 JSON 객체가 아닙니다")
            }
            return object
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.invalidSettings(error.localizedDescription)
        }
    }

    private func save(_ settings: [String: Any]) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = Self.stampFormatter.string(from: Date())
            let dir = settingsURL.deletingLastPathComponent()
            // 같은 초에 여러 번 바꿔도 처음 백업을 지우지 않는다
            var url = dir.appendingPathComponent("settings.json.bak-claude-sessions-\(stamp)")
            var n = 1
            while fm.fileExists(atPath: url.path) {
                n += 1
                url = dir.appendingPathComponent("settings.json.bak-claude-sessions-\(stamp)-\(n)")
            }
            try fm.copyItem(at: settingsURL, to: url)
            backup = url
        }
        var data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: settingsURL, options: .atomic)
        return backup
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func commands(in value: Any?) -> [String] {
        (value as? [Any] ?? []).flatMap { group -> [String] in
            let inner = (group as? [String: Any])?["hooks"] as? [Any] ?? []
            return inner.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    /// 이 앱의 hook 항목만 지운다. 비게 된 그룹·이벤트도 정리한다.
    private func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for event in Self.events {
            guard let groups = hooks[event] as? [Any] else { continue }
            let cleaned: [Any] = groups.compactMap { group in
                guard var dict = group as? [String: Any], let inner = dict["hooks"] as? [Any] else { return group }
                let kept = inner.filter { item in
                    guard let command = (item as? [String: Any])?["command"] as? String else { return true }
                    return !Self.isOurs(command)
                }
                if kept.isEmpty { return nil }
                dict["hooks"] = kept
                return dict
            }
            if cleaned.isEmpty { result.removeValue(forKey: event) } else { result[event] = cleaned }
        }
        return result
    }
}
