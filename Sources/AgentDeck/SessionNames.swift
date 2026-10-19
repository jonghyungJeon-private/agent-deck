import Foundation
import TermWire

/// 화면·세션 이름을 한곳에서 정한다(탭·왼쪽 목록·분할 테두리가 모두 이 이름을 쓴다).
/// 직접 바꾼 이름과, 첫 질문으로 지은 제목을 term/names.json 에 둔다(앱을 다시 켜도 다시 짓지 않게).
///
/// 제목 짓기는 `claude -p`(sonnet, 도구·MCP·설정·대화 저장 없이)를 세션마다 한 번 부른다. 그동안은 첫 질문 앞부분을 보여 준다.
/// `AGENTDECK_AUTO_TITLE=0` 이면 부르지 않고 첫 질문 앞부분만 쓴다.
final class SessionNames {
    struct Entry: Codable, Equatable {
        var title: String
        /// "user"(직접 바꿈) | "auto"(첫 질문으로 지음)
        var source: String
    }

    /// 제목을 새로 지었을 때(목록을 다시 그리게)
    var onChange: (() -> Void)?

    /// 데이터 위치를 옮기면 따라가도록 매번 계산한다
    private var url: URL { TermPaths.home.appendingPathComponent("names.json") }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []
    private let queue = DispatchQueue(label: "AgentDeck.titles", qos: .utility)
    private let enabled = AgentDeckEnv.value("AUTO_TITLE") != "0"

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    static func sessionKey(_ id: String) -> String { "session:\(id)" }
    static func paneKey(_ id: String) -> String { "pane:\(id)" }

    func userTitle(_ key: String) -> String? {
        lock.withLock { entries[key].flatMap { $0.source == "user" ? $0.title : nil } }
    }

    /// 이미 지어 둔 자동 제목(짓기를 새로 시작하지 않는다)
    func savedAutoTitle(session id: String) -> String? {
        lock.withLock { entries[Self.sessionKey(id)].flatMap { $0.source == "auto" ? $0.title : nil } }
    }

    /// nil 이나 빈 글이면 직접 붙인 이름을 지우고 자동 이름으로 돌아간다
    func setUserTitle(_ key: String, _ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.withLock {
            if trimmed.isEmpty {
                if entries[key]?.source == "user" { entries[key] = nil }
            } else {
                entries[key] = Entry(title: trimmed, source: "user")
            }
        }
        save()
    }

    /// 첫 질문으로 지은 제목. 아직 없으면 짓기 시작하고 nil(그동안은 부르는 쪽이 질문 앞부분을 보여 준다).
    func autoTitle(session id: String, prompt: String) -> String? {
        let key = Self.sessionKey(id)
        let start: Bool = lock.withLock {
            if let entry = entries[key], entry.source == "auto" { return false }
            guard enabled, !pending.contains(key), !failed.contains(key) else { return false }
            pending.insert(key)
            return true
        }
        if start {
            queue.async { [weak self] in self?.generate(key: key, prompt: prompt) }
        }
        return lock.withLock { entries[key].flatMap { $0.source == "auto" ? $0.title : nil } }
    }

    private func generate(key: String, prompt: String) {
        let title = Self.runClaude(prompt: prompt)
        lock.withLock {
            pending.remove(key)
            if let title {
                // 그사이 직접 이름을 바꿨으면 그대로 둔다
                if entries[key] == nil { entries[key] = Entry(title: title, source: "auto") }
            } else {
                failed.insert(key) // 이번 실행에서는 다시 부르지 않는다(질문 앞부분을 계속 쓴다)
            }
        }
        save()
        if title != nil { DispatchQueue.main.async { self.onChange?() } }
    }

    private func save() {
        let snapshot = lock.withLock { entries }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - claude -p 로 제목 짓기

    static let instruction = """
    다음은 사용자가 코딩 에이전트에게 처음 한 요청이다. 이 작업을 한눈에 알 수 있는 짧은 제목을 지어라.
    요청과 같은 언어로, 공백 포함 20자 이내, 따옴표·마침표·설명 없이 제목만 출력.

    요청:
    """

    /// 앱을 Finder 에서 띄우면 PATH 가 짧아 claude 를 못 찾으므로 흔한 설치 위치를 먼저 본다
    static let claudePath: String? = {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }()

    static func runClaude(prompt: String) -> String? {
        guard let claude = claudePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        // 설정(hook 포함)·MCP·도구·대화 저장 없이 한 번만 묻는다. 세션 기록·목록에 남지 않는다.
        process.arguments = ["-p", "--model", "sonnet", "--effort", "low", "--no-session-persistence",
                             "--strict-mcp-config", "--setting-sources", "", "--tools", ""]
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env[key] = nil }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // 질문은 표준 입력으로(--tools 는 뒤따르는 글을 모두 도구 이름으로 받는다)
        let input = Pipe()
        process.standardInput = input
        do { try process.run() } catch {
            logFailure("실행 못 함: \(error)")
            return nil
        }
        input.fileHandleForWriting.write(Data((instruction + prompt).utf8))
        try? input.fileHandleForWriting.close()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        var errorData = Data()
        let errorRead = DispatchWorkItem { errorData = err.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(execute: errorRead)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorRead.wait()
        timeout.cancel()
        guard process.terminationStatus == 0, let title = clean(String(data: data, encoding: .utf8) ?? "") else {
            logFailure("종료 \(process.terminationStatus): \(String(data: errorData + data, encoding: .utf8)?.prefix(500) ?? "")")
            return nil
        }
        return title
    }

    /// 제목 짓기가 안 될 때 이유(term/title-errors.log, 마지막 몇 개만)
    static func logFailure(_ message: String) {
        let url = TermPaths.home.appendingPathComponent("title-errors.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = (old.split(separator: "\n").suffix(20).map(String.init) + ["\(Date()) \(message)"]).joined(separator: "\n")
        try? (lines + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 첫 줄만, 앞뒤 따옴표·마침표·"제목:" 같은 머리말을 떼고 40자까지
    static func clean(_ output: String) -> String? {
        guard var line = output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        for prefix in ["제목:", "제목 :", "Title:", "title:"] where line.hasPrefix(prefix) {
            line = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*#.。 "))
        guard !line.isEmpty else { return nil }
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}
