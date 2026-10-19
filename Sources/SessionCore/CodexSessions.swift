import Foundation
import SQLite3

/// Codex 데이터는 읽기 전용으로 연다. CLI 세션 ID가 확인된 화면만 연결하며 폴더명으로 추측하지 않는다.
public struct CodexSession: Equatable {
    public var id: String
    public var cwd: String
    public var title: String
    public var transcript: String?
    public var state: String?
    public var stateAt: Date?
    public var stateSeq: Int?
    public var message: String?
    public var lastText: String?
}

public final class CodexSessions {
    public let home: URL
    public init(home: URL = CodexSessions.defaultHome) { self.home = home }
    public static var defaultHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// SQLite 버전 차이나 잠금·파일 부재는 빈 결과로 처리해 터미널에는 영향을 주지 않는다.
    private func query(_ file: String, _ sql: String, id: String) -> [[String: String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent(file).path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, i), let name = sqlite3_column_name(statement, i) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func session(_ id: String) -> CodexSession? {
        guard UUID(uuidString: id) != nil else { return nil }
        let sql = "SELECT id,cwd,rollout_path,COALESCE(NULLIF(name,''),title) AS title FROM threads WHERE id=? LIMIT 1"
        let row = query("state_5.sqlite", sql, id: id).first
            ?? query("state_5.sqlite", "SELECT id,cwd,rollout_path,title FROM threads WHERE id=? LIMIT 1", id: id).first
        let path = row?["rollout_path"] ?? locateTranscript(id)
        guard row != nil || path != nil else { return nil }
        var snapshot = CodexSession(id: id, cwd: row?["cwd"] ?? "", title: row?["title"] ?? "", transcript: path)
        if let path { snapshot = readTranscript(path, into: snapshot) }
        // 새 CLI는 대화를 SQLite로 옮긴다. rollout이 멈춰 있어도 최신 턴을 읽는다.
        if let turn = query("thread_history_1.sqlite", "SELECT status,started_at,completed_at FROM thread_turns WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1", id: id).first {
            let state: String?
            switch turn["status"] {
            case "inProgress", "in_progress", "running": state = "working"
            case "completed": state = "done"
            case "interrupted", "aborted": state = "idle"
            case "failed": state = "error"
            default: state = nil
            }
            let raw = Double(turn["completed_at"] ?? turn["started_at"] ?? "")
            let at = raw.map { Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0) }
            if let state, let at, at >= (snapshot.stateAt ?? .distantPast) {
                snapshot.state = state; snapshot.stateAt = at
            }
        }
        if let item = query("thread_history_1.sqlite", "SELECT item_json FROM thread_items WHERE thread_id=? AND item_type='agentMessage' ORDER BY rollout_ordinal DESC LIMIT 1", id: id).first?["item_json"],
           let data = item.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["text"] as? String, !text.isEmpty { snapshot.lastText = String(text.suffix(400)) }
        return snapshot
    }

    public func children(of id: String) -> [(CodexSession, String)] {
        query("state_5.sqlite", "SELECT child_thread_id,status FROM thread_spawn_edges WHERE parent_thread_id=?", id: id)
            .compactMap { row in
                guard let id = row["child_thread_id"], let session = session(id) else { return nil }
                return (session, row["status"] ?? "")
            }
    }

    private var transcriptPaths: [String: String] = [:]
    private var lastIndex = Date.distantPast
    private func locateTranscript(_ id: String) -> String? {
        if Date().timeIntervalSince(lastIndex) > 30 {
            lastIndex = Date()
            if let files = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"), includingPropertiesForKeys: nil) {
                for case let url as URL in files where url.pathExtension == "jsonl" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    let key = String(stem.suffix(36))
                    if UUID(uuidString: key) != nil { transcriptPaths[key] = url.path }
                }
            }
        }
        return transcriptPaths[id]
    }

    private var cache: [String: (UInt64, Date, CodexSession)] = [:]
    private func readTranscript(_ path: String, into initial: CodexSession) -> CodexSession {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date else { return initial }
        if let old = cache[path], old.0 == size, old.1 == modified {
            var snapshot = old.2
            if !initial.title.isEmpty { snapshot.title = initial.title }
            if !initial.cwd.isEmpty { snapshot.cwd = initial.cwd }
            return snapshot
        }
        guard let file = FileHandle(forReadingAtPath: path) else { return initial }
        defer { try? file.close() }
        var snapshot = initial
        let head = (try? file.read(upToCount: 256 << 10)) ?? Data()
        let offset = size > 1 << 20 ? size - UInt64(1 << 20) : 0
        try? file.seek(toOffset: offset)
        let tail = (try? file.read(upToCount: 1 << 20)) ?? Data()
        // 앞부분과 끝부분만 읽어 큰 기록 전체를 2초마다 파싱하지 않는다.
        for data in [head, tail] {
            for line in data.split(separator: 10) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { continue }
                if type == "session_meta", snapshot.cwd.isEmpty { snapshot.cwd = payload["cwd"] as? String ?? "" }
                if type == "response_item", payload["type"] as? String == "message" {
                    let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if payload["role"] as? String == "user", snapshot.title.isEmpty,
                       !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md") { snapshot.title = String(text.prefix(160)) }
                    if payload["role"] as? String == "assistant", !text.isEmpty { snapshot.lastText = String(text.suffix(400)) }
                }
                guard type == "event_msg", let event = payload["type"] as? String,
                      let stamp = object["timestamp"] as? String, let at = Self.date(stamp),
                      at >= (snapshot.stateAt ?? .distantPast) else { continue }
                switch event {
                case "task_started": snapshot.state = "working"
                case "task_complete", "task_completed": snapshot.state = "done"
                case "turn_aborted": snapshot.state = "idle"
                case "error": snapshot.state = "error"
                default: continue
                }
                snapshot.stateAt = at
            }
        }
        cache[path] = (size, modified, snapshot)
        return snapshot
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public enum CodexArguments {
    /// node 래퍼와 백그라운드 명령은 제외하고 실제 대화형 CLI만 고른다.
    public static func isInteractive(_ args: [String]) -> Bool {
        guard let first = args.first, (first as NSString).lastPathComponent == "codex" else { return false }
        let commands: Set<String> = ["exec", "e", "review", "app-server", "exec-server", "mcp", "login", "logout", "debug", "sandbox", "completion", "features", "doctor", "update", "agents", "queue", "app", "cloud", "remote-control", "apply", "archive", "delete", "unarchive", "migrate-rollouts"]
        var index = 1
        let valueOptions: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "-i", "--image", "--enable", "--disable", "--remote", "--remote-auth-token-env"]
        while index < args.count {
            let arg = args[index]; index += 1
            if valueOptions.contains(arg) { index += 1; continue }
            if ["--help", "-h", "--version", "-V"].contains(arg) { return false }
            if commands.contains(arg) { return false }
            if !arg.hasPrefix("-") { return true }
        }
        return true
    }
    public static func sessionId(_ args: [String]) -> String? {
        guard let resume = args.firstIndex(of: "resume"), args.indices.contains(resume + 1),
              UUID(uuidString: args[resume + 1]) != nil else { return nil }
        return args[resume + 1]
    }
    public static func keptArgs(_ args: [String]) -> [String] {
        let values: Set<String> = ["-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "--add-dir", "-c", "--config", "--enable", "--disable", "--local-provider"]
        // 권한 관련 옵션은 그 세션에서 이미 지정된 것만 이어받는다.
        let flags: Set<String> = ["--yolo", "--dangerously-bypass-approvals-and-sandbox", "--approve-for-me", "--search", "--no-alt-screen", "--no-daemon", "--oss", "--strict-config"]
        var result: [String] = []; var i = 1
        while i < args.count {
            let arg = args[i]; i += 1
            let key = String(arg.split(separator: "=", maxSplits: 1).first ?? "")
            if values.contains(key) {
                if arg.contains("=") { result.append(arg) }
                else if i < args.count, !args[i].hasPrefix("-") { result += [arg, args[i]]; i += 1 }
            } else if flags.contains(arg) { result.append(arg) }
        }
        return result
    }
}
