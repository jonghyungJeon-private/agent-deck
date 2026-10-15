import Foundation

public enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 앱 데이터 위치. 테스트·개발용으로 CLAUDE_SESSIONS_HOME 으로 바꿀 수 있다.
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_SESSIONS_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/ClaudeSessions", isDirectory: true)
    }

    public static var sessionsDir: URL { appSupport.appendingPathComponent("sessions", isDirectory: true) }
    public static var hookErrorLog: URL { appSupport.appendingPathComponent("hook-errors.log") }

    public static var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }
    public static var claudeProjects: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }
}
