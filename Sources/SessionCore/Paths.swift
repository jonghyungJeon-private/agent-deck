import Foundation
import TermWire

public enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 앱 데이터 위치(DataLocation.root). 테스트·개발용으로 AGENTDECK_HOME(예전 CLAUDE_SESSIONS_HOME)으로 바꿀 수 있다.
    public static var appSupport: URL { DataLocation.root }

    public static var sessionsDir: URL { appSupport.appendingPathComponent("sessions", isDirectory: true) }
    public static var hookErrorLog: URL { appSupport.appendingPathComponent("hook-errors.log") }

    /// Claude Code 설정 폴더. Claude Code 와 같이 CLAUDE_CONFIG_DIR 를 따른다(시험할 때 실제 설정과 떼어 놓는 데도 쓴다).
    public static var claudeDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }
    public static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }
    public static var claudeProjects: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }
}
