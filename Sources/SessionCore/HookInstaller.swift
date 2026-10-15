import Foundation

/// ~/.claude/settings.json 에 이 앱의 SessionStart / SessionEnd hook 을 넣고 뺀다.
/// 사용자의 다른 설정·hook 은 그대로 두고, 바꾸기 전에 백업을 남긴다.
public struct HookInstaller {
    /// 세션 기록(SessionStart/End)과 작업 상태(나머지) hook
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "StopFailure", "Notification",
                                "PermissionRequest"]
    /// 같은 세션 기록(SessionStore)을 남기는 hook 의 실행 파일 이름들. ClaudeSessions 앱은 ClaudeTerm 으로 바뀌어 정리 대상이다.
    public static let legacyMarkers = ["ClaudeSessions"]

    public let eventNames: [String]
    public let subcommand: String
    public let settingsURL: URL
    public let executablePath: String
    /// 이 앱이 넣은 hook 인지 알아보는 표식(실행 파일 이름). 경로가 바뀌어도(앱 이동) 찾을 수 있게 끝부분만 본다.
    public let marker: String

    public init(settingsURL: URL = Paths.claudeSettings, executablePath: String, marker: String = "ClaudeSessions",
                events: [String] = HookInstaller.events, subcommand: String = "hook") {
        self.eventNames = events
        self.subcommand = subcommand
        self.settingsURL = settingsURL
        self.executablePath = executablePath
        self.marker = marker
    }

    static func suffix(_ marker: String) -> String { "\(marker)\" hook" }

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
        return "\"\(escaped)\" \(subcommand)"
    }

    func isOurs(_ command: String) -> Bool { command.hasSuffix("\(marker)\" \(subcommand)") }

    /// 지금 settings.json 의 이 앱 hook 이 가리키는 실행 파일들
    public func installedExecutablePaths() throws -> [String] {
        let hooks = try loadSettings()["hooks"] as? [String: Any] ?? [:]
        return eventNames.flatMap { commands(in: hooks[$0]) }.filter(isOurs).compactMap { command in
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
        for event in eventNames {
            for command in commands(in: hooks[event]) where isOurs(command) {
                found += 1
                if command == self.command { current += 1 }
            }
        }
        if found == 0 { return .notInstalled }
        return current == eventNames.count && found == current ? .installed : .outdated
    }

    /// 같은 기록을 남기는 다른(예전) 앱의 hook 이 남아 있는지
    public func hasLegacyHooks() throws -> Bool {
        let hooks = try loadSettings()["hooks"] as? [String: Any] ?? [:]
        return eventNames.flatMap { commands(in: hooks[$0]) }.contains { command in
            Self.legacyMarkers.filter { $0 != marker }.contains { command.hasSuffix(Self.suffix($0)) }
        }
    }

    /// 이미 있던 이 앱의 hook 은 지우고 현재 경로로 다시 넣는다. replacingLegacy 면 예전 앱(ClaudeSessions)의 hook 도 뺀다
    /// (같은 기록을 두 번 남기지 않게, 그 앱을 지워도 hook 이 깨지지 않게). 백업 경로를 돌려준다(원본이 없었으면 nil).
    @discardableResult
    public func install(replacingLegacy: Bool = false) throws -> URL? {
        var settings = try loadSettings()
        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:],
                                 also: replacingLegacy ? Self.legacyMarkers.filter { $0 != marker } : [])
        for event in eventNames {
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
            var url = dir.appendingPathComponent("\(settingsURL.lastPathComponent).bak-claude-sessions-\(stamp)")
            var n = 1
            while fm.fileExists(atPath: url.path) {
                n += 1
                url = dir.appendingPathComponent("\(settingsURL.lastPathComponent).bak-claude-sessions-\(stamp)-\(n)")
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

    /// 이 앱의 hook 항목만 지운다(also 의 표식도 함께). 비게 된 그룹·이벤트도 정리한다.
    private func removingOurs(from hooks: [String: Any], also: [String] = []) -> [String: Any] {
        let suffixes = ([marker] + also).map { "\($0)\" \(subcommand)" }
        var result = hooks
        for event in eventNames {
            guard let groups = hooks[event] as? [Any] else { continue }
            let cleaned: [Any] = groups.compactMap { group in
                guard var dict = group as? [String: Any], let inner = dict["hooks"] as? [Any] else { return group }
                let kept = inner.filter { item in
                    guard let command = (item as? [String: Any])?["command"] as? String else { return true }
                    return !suffixes.contains { command.hasSuffix($0) }
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
