import Foundation

/// Claude Code 세션 안에서(예: 그 세션의 셸에서 `open`) 앱을 띄우면 그 세션의 표시용 환경 변수가 앱으로 넘어오고,
/// 앱이 켜는 터미널 → 그 안의 claude 까지 이어져 "CLAUDE_CODE_CHILD_SESSION … Transcript saving is off" 가 된다.
/// 앱(hook 모드 제외)은 시작할 때 이 변수들을 지운다. 사용자 설정용 변수는 터미널 셸이 설정 파일에서 다시 읽는다.
public enum InheritedEnvironment {
    public static func isClaudeSessionMarker(_ key: String) -> Bool {
        key == "CLAUDECODE" || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" || key.hasPrefix("CLAUDE_CODE_")
    }

    @discardableResult
    public static func scrub(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let keys = environment.keys.filter { isClaudeSessionMarker($0) || $0 == "CODEX_THREAD_ID" }.sorted()
        keys.forEach { unsetenv($0) }
        return keys
    }

    /// 표시 변수가 있으면 지운 환경으로 자기 자신을 다시 실행한다(같은 PID).
    /// 이후 이 앱이 띄우는 모든 프로세스·터미널이 처음부터 깨끗한 환경을 받는다. 다시 실행하지 않았으면 그냥 돌아온다.
    public static func reexecIfNeeded(executablePath: String?) {
        guard let path = executablePath, !scrub().isEmpty else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(path, argv) // 성공하면 돌아오지 않는다. 실패해도 이미 지운 환경으로 계속 진행.
    }
}
