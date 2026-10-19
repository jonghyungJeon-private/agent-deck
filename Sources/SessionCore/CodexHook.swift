import Foundation
import TermWire
import Darwin

/// Codex 훅은 관찰만 한다. 승인 결정이나 문맥을 stdout 에 반환하지 않는다.
public enum CodexHook {
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt"]
    public static var store: SessionStore { SessionStore(dir: Paths.appSupport.appendingPathComponent("codex-sessions")) }

    public static func handle(_ data: Data, environment: [String: String] = ProcessInfo.processInfo.environment,
                              store: SessionStore = CodexHook.store, now: Date = Date()) throws {
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["session_id"] as? String, UUID(uuidString: id) != nil,
              let event = input["hook_event_name"] as? String, events.contains(event),
              input["agent_id"] == nil,
              let pane = AgentDeckEnv.value("PANE", in: environment), !pane.isEmpty else { return }
        try store.withLock {
            var record = store.load(id) ?? SessionRecord(sessionId: id, cwd: input["cwd"] as? String ?? "",
                transcriptPath: input["transcript_path"] as? String, pid: 0, pidStartedAt: 0, startedAt: now)
            record.pane = pane
            record.cwd = input["cwd"] as? String ?? record.cwd
            record.transcriptPath = input["transcript_path"] as? String ?? record.transcriptPath
            record.stateMessage = nil
            switch event {
            case "SessionStart", "Interrupt": record.state = "idle"
            case "SessionEnd": record.state = "idle"; record.endedAt = now
            case "PermissionRequest": record.state = "waiting"; record.stateMessage = "권한 요청"
            case "Stop": record.state = "done"
            case "PreToolUse" where (input["tool_name"] as? String ?? "").contains("request_user_input"):
                record.state = "waiting"; record.stateMessage = "질문에 답변 필요"
            default: record.state = "working"
            }
            if event != "SessionEnd" { record.endedAt = nil }
            record.stateAt = now
            record.stateSeq = (record.stateSeq ?? 0) + 1
            try store.save(record)
        }
    }
    public static func run() -> Int32 {
        try? handle(FileHandle.standardInput.readDataToEndOfFile())
        return 0
    }
}
