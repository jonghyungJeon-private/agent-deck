import Foundation

/// 화면(칸)에서 `agentdeck` 명령을 쓰게 하는 것. 데몬이 만드는 모든 칸의 환경에 `AGENTDECK_PANE_ID`(칸 ID)와
/// PATH 앞의 `agentdeck` 를 넣어, AgentDeck 안의 셸·claude·codex 는 설치 없이 `agentdeck` 를 쓴다
/// (이미 떠 있는 칸은 그때의 환경 그대로라 새로 띄운 칸부터).
public enum CliBinding {
    public static let paneVariable = "AGENTDECK_PANE_ID"

    /// 앱 묶음의 `Contents/Helpers/agentdeck`(같은 묶음의 AgentDeckDaemon 으로 가는 링크 — 이름이 agentdeck 로 불리면 cli 로 동작한다). 없으면 nil(개발 빌드).
    public static func bundledHelper(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let executable else { return nil }
        let helper = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../Helpers/agentdeck").standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// `BrowserBinding.binDir/agentdeck` 를 맞춘다(데몬이 뜰 때). 묶음의 Helpers 를 그대로 PATH 에 넣지 않고 작은 스크립트 하나만 두는 것은
    /// abx 와 같은 까닭이다(엔진 실행 파일이 PATH 에 보이지 않게). 묶음의 링크가 없으면(개발 빌드) 데몬 실행 파일의 `cli` 를 부른다.
    /// 돌려주는 값은 PATH 에 넣을 폴더(만들지 못하면 nil).
    @discardableResult
    public static func installShim(helper: URL?, daemon: URL?, termDir: URL = TermPaths.home) -> URL? {
        let dir = BrowserBinding.binDir(termDir: termDir)
        let shim = dir.appendingPathComponent("agentdeck")
        let command: String
        // 데몬 실행 파일 + "cli" 를 먼저 쓴다: 링크(Helpers/agentdeck) 경로는 풀려서 실행 파일 이름이 AgentDeckDaemon 으로 보일 수 있어
        // 이름으로 cli 를 고르는 방식에 기대면 `agentdeck list` 가 데몬 시작으로 잘못 갈 수 있다(격리 시험에서 실제로 그랬다).
        if let daemon {
            command = quote(daemon.path) + " cli"
        } else if let helper {
            command = quote(helper.path)
        } else {
            try? FileManager.default.removeItem(at: shim)
            return nil
        }
        let script = "#!/bin/sh\n# AgentDeck 이 칸에 주는 agentdeck 명령 — 앱 묶음의 것을 실행한다(데몬이 뜰 때 다시 쓴다)\nexec \(command) \"$@\"\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: shim, encoding: .utf8)) != script {
                try Data(script.utf8).write(to: shim, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            return dir
        } catch {
            return nil
        }
    }

    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 앱 밖 터미널에서 쓰는 링크 위치(설정 → 연결의 "터미널에서도 agentdeck 쓰기")
    public static func userLink(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/agentdeck")
    }
}
