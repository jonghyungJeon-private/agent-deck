import Darwin
import Foundation
import TermWire

/// 메인 claude 가 응답을 마친 뒤에도 도는 백그라운드 일 하나(Stop hook 의 `background_tasks` 항목).
public struct BackgroundTask: Codable, Equatable, Sendable {
    public var id: String
    /// Claude Code 가 붙인 종류 이름: subagent, shell, monitor, workflow, teammate, cloud session, MCP task …
    public var type: String

    public init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    public enum Kind: Equatable, Sendable {
        /// 에이전트(하위 에이전트·팀원·워크플로·클라우드 세션)
        case agent
        /// 백그라운드 셸·모니터·MCP 작업(모르는 종류도 여기)
        case shell
        /// Claude Code 내부 정리 일(사람이 맡긴 일이 아니다)
        case ignored
    }

    public var kind: Kind {
        switch type {
        case "subagent", "local_agent", "teammate", "in_process_teammate", "workflow", "local_workflow",
             "cloud session", "remote_agent":
            return .agent
        case "dream", "auto-mode scan", "auto_mode_scan", "memory import", "local_memory_import":
            return .ignored
        default:
            return .shell
        }
    }

    /// 하위 에이전트 기록 파일로 확인할 수 있는 종류
    var isSubagent: Bool { type == "subagent" || type == "local_agent" }
}

/// hook 입력의 `background_tasks`. 모양이 낯설어도 hook 전체를 실패시키지 않게 너그럽게 읽는다.
struct BackgroundTaskList: Decodable {
    /// 배열이 아니면 nil(모름)
    var tasks: [BackgroundTask]?

    private struct Entry: Decodable {
        var id: String?
        var type: String?
        var status: String?
        enum CodingKeys: String, CodingKey { case id, type, status }
        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? c?.decode(String.self, forKey: .id)
            type = try? c?.decode(String.self, forKey: .type)
            status = try? c?.decode(String.self, forKey: .status)
        }
    }

    init(from decoder: Decoder) throws {
        guard var list = try? decoder.unkeyedContainer() else { return }
        var tasks: [BackgroundTask] = []
        while !list.isAtEnd {
            guard let entry = try? list.decode(Entry.self) else { break }
            // Claude Code 는 running·pending 만 넣지만, 끝난 것이 섞여도 세지 않게
            guard let id = entry.id, !id.isEmpty, entry.status.map({ $0 == "running" || $0 == "pending" }) ?? true
            else { continue }
            let task = BackgroundTask(id: id, type: entry.type ?? "")
            if task.kind != .ignored { tasks.append(task) }
        }
        self.tasks = tasks
    }
}

/// 백그라운드 일이 아직 도는지 파일로 확인한다(가볍게: 일마다 stat 과 작은 읽기 한두 번).
/// - 하위 에이전트: `<대화 파일 폴더>/<세션>/subagents/agent-<id>.meta.json` 의 `"finished":true`(2.1 대 — 다시 이어 시키면 빠진다),
///   없으면 기록 끝의 마지막 assistant 가 end_turn 이고 그 뒤에 user 줄이 없을 때 끝난 것으로 본다(예전 판).
/// - 셸 등: `<tmp>/claude-<uid>/<프로젝트 폴더>/<세션>/tasks/<id>.output` 끝 줄이 `[exited with code N]`·`[killed]`.
///   셸 출력 파일이 없어졌으면(폴더는 있음) 끝난 것으로 본다. 그 밖에 확인할 수 없으면 hook 을 믿는다(도는 것으로).
public enum BackgroundWork {
    public enum TaskState: Equatable {
        /// 돈다. 에이전트면 기록이 마지막으로 바뀐 시각
        case running(activeAt: Date?)
        case ended(at: Date)
    }

    /// claude 가 백그라운드 출력을 두는 곳. 시험용으로 `AGENTDECK_CLAUDE_TMP` 로 바꾼다.
    public static var tmpRoot: URL {
        if let path = AgentDeckEnv.nonEmpty("CLAUDE_TMP") { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
    }

    /// Stop 때 남긴 목록을 지금 파일로 확인한 결과
    public static func inspect(_ tasks: [BackgroundTask], transcriptPath: String?, sessionId: String,
                               stoppedAt: Date, tmpRoot: URL = BackgroundWork.tmpRoot) -> WorkStateRules.Background {
        var result = WorkStateRules.Background()
        let transcript = transcriptPath.map { URL(fileURLWithPath: $0) }
        let subagents = transcript.map { $0.deletingPathExtension().appendingPathComponent("subagents") }
        let tasksDir = transcript.map {
            tmpRoot.appendingPathComponent($0.deletingLastPathComponent().lastPathComponent)
                .appendingPathComponent(sessionId).appendingPathComponent("tasks")
        }
        for task in tasks where task.kind != .ignored {
            switch state(of: task, subagentsDir: subagents, tasksDir: tasksDir, stoppedAt: stoppedAt) {
            case .running(let active):
                if task.kind == .agent { result.agents += 1 } else { result.shells += 1 }
                if let active, active > (result.lastActiveAt ?? .distantPast) { result.lastActiveAt = active }
            case .ended(let at):
                if at > (result.lastEndedAt ?? .distantPast) { result.lastEndedAt = at }
            }
        }
        return result
    }

    static func state(of task: BackgroundTask, subagentsDir: URL?, tasksDir: URL?, stoppedAt: Date) -> TaskState {
        if task.isSubagent, let dir = subagentsDir, isSafeId(task.id) {
            let base = task.id.hasPrefix("agent-") ? task.id : "agent-" + task.id
            let log = dir.appendingPathComponent(base + ".jsonl")
            if let modified = modifiedAt(log.path) {
                let metaURL = dir.appendingPathComponent(base + ".meta.json")
                if agentEnded(meta: try? Data(contentsOf: metaURL), tail: readTail(log.path, bytes: 64 * 1024)) {
                    return .ended(at: max(modified, modifiedAt(metaURL.path) ?? modified))
                }
                return .running(activeAt: modified)
            }
        }
        guard let dir = tasksDir, isSafeId(task.id) else { return .running(activeAt: nil) }
        let output = dir.appendingPathComponent(task.id + ".output")
        // 에이전트 출력은 에이전트 기록으로 가는 링크라 위에서 본다. 여기는 셸 등.
        if let modified = modifiedAt(output.path) {
            return outputEnded(readTail(output.path, bytes: 256)) ? .ended(at: modified) : .running(activeAt: nil)
        }
        // 셸인데 출력 폴더는 있고 파일이 없다 → 정리된 것(끝남). 폴더가 없거나 파일을 안 남기는 종류(워크플로·팀원 등)는
        // 확인할 수 없으니 hook 을 믿는다(다음 hook 이 바로잡는다).
        if task.type == "shell" || task.type == "local_bash", FileManager.default.fileExists(atPath: dir.path) {
            return .ended(at: stoppedAt)
        }
        return .running(activeAt: nil)
    }

    /// 셸 출력 끝에 Claude Code 가 붙이는 끝 표시(`[exited with code 0]`, `[killed]`)
    public static func outputEnded(_ tail: Data) -> Bool {
        guard let text = String(data: tail, encoding: .utf8) ?? String(data: tail.dropFirst(min(3, tail.count)), encoding: .utf8)
        else { return false }
        let last = text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return last == "[killed]" || (last.hasPrefix("[exited with code ") && last.hasSuffix("]"))
    }

    /// 하위 에이전트가 끝났는가: meta 의 finished, 없으면 기록 끝(마지막 assistant 가 end_turn 이고 그 뒤 user 줄 없음).
    /// 기록은 압축된 JSON 한 줄씩이라 바이트 표식으로 찾는다.
    public static func agentEnded(meta: Data?, tail: Data) -> Bool {
        if let meta, let object = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
           object["finished"] as? Bool == true {
            return true
        }
        let assistant = Data(#""type":"assistant""#.utf8)
        let user = Data(#""type":"user""#.utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            if line.range(of: user) != nil, line.range(of: assistant) == nil { return false }
            guard line.range(of: assistant) != nil else { continue }
            return line.range(of: Data(#""stop_reason":"end_turn""#.utf8)) != nil
        }
        return false
    }

    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func modifiedAt(_ path: String) -> Date? { WorkStateRules.transcriptModifiedAt(path) }

    static func readTail(_ path: String, bytes: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return handle.readDataToEndOfFile()
    }
}
