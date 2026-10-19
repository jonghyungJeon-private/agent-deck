import Foundation

/// ~/.claude/settings.json(Codex 는 ~/.codex/hooks.json)에 이 앱의 hook 을 넣고 뺀다.
/// 사용자의 다른 설정·hook 은 그대로 두고, 바꾸기 전에 백업(<파일>.agentdeck-backup-<시각>)을 남긴다.
public struct HookInstaller {
    /// 세션 기록(SessionStart/End)과 작업 상태(나머지) hook
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "StopFailure", "Notification",
                                "PermissionRequest"]
    /// 이 앱 hook 으로 알아보는 실행 파일 이름. 첫 것이 지금 이름이고, 나머지는 예전 이름
    /// (ClaudeTermDaemon = 0.3 까지의 AgentDeck/ClaudeTerm, ClaudeSessions = 그 전 앱) — 찾으면 "갱신하기" 대상, 연결 해제 때 함께 뺀다.
    public static let knownMarkers = ["AgentDeckDaemon", "ClaudeTermDaemon", "ClaudeSessions"]

    public let eventNames: [String]
    public let subcommand: String
    public let settingsURL: URL
    public let executablePath: String
    /// 이 앱이 넣은 hook 인지 알아보는 표식(실행 파일 이름들). 경로가 바뀌어도(앱 이동) 찾을 수 있게 끝부분만 본다.
    public let markers: [String]

    public init(settingsURL: URL = Paths.claudeSettings, executablePath: String, markers: [String] = HookInstaller.knownMarkers,
                events: [String] = HookInstaller.events, subcommand: String = "hook") {
        self.eventNames = events
        self.subcommand = subcommand
        self.settingsURL = settingsURL
        self.executablePath = executablePath
        self.markers = markers
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

    /// hook 은 셸(sh -c)로 실행된다. 앱을 지우거나 옮겨 실행 파일이 없으면 아무것도 하지 않고 성공(0)으로 끝나,
    /// 어느 터미널의 claude·codex 에도 hook 오류가 나지 않는다. 있으면 exec 로 바꿔 끼워 stdin·종료 코드를 그대로 넘긴다.
    public var command: String { Self.guardedCommand(executablePath, subcommand) }

    public static func guardedCommand(_ path: String, _ subcommand: String) -> String {
        let quoted = shellQuoted(path)
        return "[ -x \(quoted) ] || exit 0; exec \(quoted) \(subcommand)"
    }

    /// 0.1 까지 넣던 형태(실행 파일이 없으면 hook 마다 오류). 찾아서 갱신 대상으로 본다.
    public static func unguardedCommand(_ path: String, _ subcommand: String) -> String {
        "\(shellQuoted(path)) \(subcommand)"
    }

    /// 큰따옴표 안에서 뜻이 있는 글자(" \\ $ `)만 \\ 로 막는다(POSIX sh)
    static func shellQuoted(_ path: String) -> String {
        let escaped = path.reduce(into: "") { out, ch in
            if "\"\\$`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// 표식(실행 파일 이름)으로 끝나는 명령이면 이 앱 것: 지금 형태·예전 형태(가드 없음) 모두 `…/<표식>" <하위 명령>` 으로 끝난다.
    /// 예전 이름(ClaudeTermDaemon·ClaudeSessions)도 이 앱 것으로 보되, 지금 명령과 다르니 status 는 outdated 가 된다.
    func isOurs(_ command: String) -> Bool { markers.contains { command.hasSuffix("\($0)\" \(subcommand)") } }

    /// 명령이 실행하는 파일 경로(마지막 큰따옴표 묶음을 풀어서)
    static func executablePath(in command: String) -> String? {
        var last: String?, current: String?, escaping = false
        for ch in command {
            guard var text = current else {
                if ch == "\"" { current = "" }
                continue
            }
            if escaping {
                text.append(ch); escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == "\"" {
                last = text; current = nil; continue
            } else {
                text.append(ch)
            }
            current = text
        }
        return last
    }

    /// 지금 settings.json 의 이 앱 hook 이 가리키는 실행 파일들
    public func installedExecutablePaths() throws -> [String] {
        let hooks = try loadSettings()["hooks"] as? [String: Any] ?? [:]
        return eventNames.flatMap { commands(in: hooks[$0]) }.filter(isOurs).compactMap(Self.executablePath(in:))
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

    /// 이미 있던 이 앱의 hook(예전 이름 포함)은 지우고 현재 경로로 다시 넣는다
    /// (같은 기록을 두 번 남기지 않게, 예전 앱을 지워도 hook 이 깨지지 않게). 백업 경로를 돌려준다(원본이 없었으면 nil).
    @discardableResult
    public func install() throws -> URL? {
        var settings = try loadSettings()
        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        for event in eventNames {
            var groups = hooks[event] as? [Any] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return try save(settings)
    }

    public struct Removal: Equatable {
        /// 지운 hook 항목 수(0 이면 파일을 건드리지 않았다)
        public var removed: Int
        public var backup: URL?
    }

    /// 이 앱의 hook 만 뺀다(경로와 상관없이 표식으로 찾는다 — 다른 위치·예전 이름의 이 앱 것도). 지울 것이 없으면 파일을 그대로 둔다.
    @discardableResult
    public func uninstall() throws -> Removal {
        var settings = try loadSettings()
        let before = settings["hooks"] as? [String: Any] ?? [:]
        let count = before.values.reduce(0) { $0 + commands(in: $1).filter(isOurs).count }
        guard count > 0 else { return Removal(removed: 0, backup: nil) }
        let hooks = removingOurs(from: before)
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return Removal(removed: count, backup: try save(settings))
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
            var url = dir.appendingPathComponent("\(settingsURL.lastPathComponent).agentdeck-backup-\(stamp)")
            var n = 1
            while fm.fileExists(atPath: url.path) {
                n += 1
                url = dir.appendingPathComponent("\(settingsURL.lastPathComponent).agentdeck-backup-\(stamp)-\(n)")
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
        // 모든 이벤트를 본다(예전 판이 넣은, 지금 목록에 없는 이벤트의 hook 도 지우게)
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let cleaned: [Any] = groups.compactMap { group in
                guard var dict = group as? [String: Any], let inner = dict["hooks"] as? [Any] else { return group }
                let kept = inner.filter { item in
                    guard let command = (item as? [String: Any])?["command"] as? String else { return true }
                    return !isOurs(command)
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

public extension HookInstaller {
    /// hook 은 데몬 실행 파일이 맡는다(AppKit 을 띄우지 않아 가볍다). 표식은 앱 안 실행 파일 이름이라
    /// 앱이 놓인 곳·묶음 이름과 상관없이 같은 hook 으로 알아본다.
    static let daemonExecutable = "AgentDeckDaemon"

    static func claude(daemonPath: String, settingsURL: URL = Paths.claudeSettings) -> HookInstaller {
        HookInstaller(settingsURL: settingsURL, executablePath: daemonPath)
    }

    static func codex(daemonPath: String, hooksURL: URL = CodexSessions.defaultHome.appendingPathComponent("hooks.json")) -> HookInstaller {
        HookInstaller(settingsURL: hooksURL, executablePath: daemonPath, events: CodexHook.events, subcommand: "codex-hook")
    }
}

/// `AgentDeckDaemon unhook [--claude-settings <파일>] [--codex-hooks <파일>]`: 이 앱의 hook 만 뺀다(삭제 스크립트가 쓴다).
/// 다른 hook·설정은 그대로, 바꾸기 전 백업. 설정 파일을 읽지 못하면 고치지 않고 1 로 끝난다.
public enum Unhook {
    public static func run(_ arguments: [String], output: (String) -> Void = { print($0) }) -> Int32 {
        var claude = Paths.claudeSettings
        var codex = CodexSessions.defaultHome.appendingPathComponent("hooks.json")
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst(), ["--claude-settings", "--codex-hooks"].contains(flag) else {
                output("사용: AgentDeckDaemon unhook [--claude-settings <파일>] [--codex-hooks <파일>]")
                return 2
            }
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            if flag == "--claude-settings" { claude = url } else { codex = url }
        }
        var failed = false
        for (label, installer) in [("Claude Code", HookInstaller.claude(daemonPath: "", settingsURL: claude)),
                                   ("Codex", HookInstaller.codex(daemonPath: "", hooksURL: codex))] {
            let path = (installer.settingsURL.path as NSString).abbreviatingWithTildeInPath
            do {
                let result = try installer.uninstall()
                if result.removed == 0 {
                    output("\(label): \(path) 에 이 앱의 hook 이 없습니다")
                } else {
                    output("\(label): \(path) 에서 hook \(result.removed)개를 뺐습니다"
                           + (result.backup.map { " (백업: \(($0.path as NSString).abbreviatingWithTildeInPath))" } ?? ""))
                }
            } catch {
                failed = true
                output("\(label): \(path) 를 고치지 못해 그대로 둡니다 — \(error.localizedDescription)")
            }
        }
        return failed ? 1 : 0
    }
}
