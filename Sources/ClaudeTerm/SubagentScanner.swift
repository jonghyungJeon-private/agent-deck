import Foundation

/// claude 세션이 띄운 하위 에이전트(Agent 도구) 하나의 최근 활동
struct SubagentActivity: Identifiable, Equatable {
    /// 에이전트 기록 파일 이름(agent-xxxx)
    var id: String
    var sessionId: String
    /// 이 에이전트를 띄운 claude 가 도는 화면
    var paneId: String
    var description: String
    var agentType: String?
    /// 기록에 가장 많이 나온 작업 트리(없으면 nil)
    var worktreePath: String?
    var lastActive: Date
    /// 마지막으로 남긴 글(펼쳐 볼 때)
    var lastText: String?

    /// 최근 1분 안에 기록이 늘었으면 일하는 중으로 본다
    var isRunning: Bool { Date().timeIntervalSince(lastActive) < 60 }
}

/// 하위 에이전트 기록(~/.claude/projects/<폴더>/<세션>/subagents/agent-*.jsonl)을 훑어 어느 작업 트리에서 일하는지 알아낸다.
/// claude 프로세스와 하위 에이전트는 메인 폴더에서 돌고 작업 트리는 경로로만 쓰므로, 작업 폴더(cwd)로는 알 수 없다.
/// 가볍게: 최근 15분 안에 바뀐 파일만, 끝 64KB 만 읽고, 크기가 그대로인 파일은 다시 읽지 않는다. worker 에서만 쓴다.
final class SubagentScanner {
    static let window: TimeInterval = 15 * 60
    static let tailBytes = 64 * 1024

    private struct Cached {
        var size: UInt64
        var worktree: String?
        var lastText: String?
    }

    private var cache: [String: Cached] = [:]
    private var meta: [String: (description: String, type: String?)] = [:]

    /// sessions: (화면 ID, 세션 ID, 대화 파일 경로, 그 저장소의 작업 트리 경로들)
    func scan(_ sessions: [(paneId: String, sessionId: String, transcript: String, worktrees: [String])]) -> [SubagentActivity] {
        let fm = FileManager.default
        var result: [SubagentActivity] = []
        var seen: Set<String> = []
        for session in sessions {
            let dir = URL(fileURLWithPath: (session.transcript as NSString).deletingPathExtension).appendingPathComponent("subagents")
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < Self.window
                else { continue }
                let path = file.path
                seen.insert(path)
                let size = UInt64(values.fileSize ?? 0)
                var entry = cache[path]
                if entry?.size != size {
                    let tail = Self.readTail(path)
                    entry = Cached(size: size, worktree: Self.mostMentioned(session.worktrees, in: tail), lastText: Self.lastText(in: tail))
                    cache[path] = entry
                }
                let name = file.deletingPathExtension().lastPathComponent
                let info = meta[path] ?? {
                    let metaURL = file.deletingPathExtension().appendingPathExtension("meta.json")
                    let object = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let value = ((object?["description"] as? String) ?? name, object?["agentType"] as? String)
                    meta[path] = value
                    return value
                }()
                result.append(SubagentActivity(id: name, sessionId: session.sessionId, paneId: session.paneId,
                                               description: info.description, agentType: info.type,
                                               worktreePath: entry?.worktree, lastActive: modified, lastText: entry?.lastText))
            }
        }
        // 창 밖으로 나간 파일의 캐시는 버린다
        cache = cache.filter { seen.contains($0.key) }
        meta = meta.filter { seen.contains($0.key) }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    static func readTail(_ path: String) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return handle.readDataToEndOfFile()
    }

    /// 끝부분에 가장 많이 나온 작업 트리 경로(메인 폴더는 빼고 넘겨받는다)
    static func mostMentioned(_ worktrees: [String], in data: Data) -> String? {
        var best: (path: String, count: Int)?
        for path in worktrees {
            let count = occurrences(of: Data(path.utf8), in: data)
            if count > 0, count > (best?.count ?? 0) { best = (path, count) }
        }
        return best?.path
    }

    /// 경로가 정확히 끝나는 곳만 센다(claude-v5-a6 가 claude-v5-a6-fix 안에서 세지지 않게). 바이트로 찾는다(글자 단위는 느리다).
    static func occurrences(of needle: Data, in data: Data) -> Int {
        var count = 0
        var start = data.startIndex
        while start < data.endIndex, let found = data.range(of: needle, in: start..<data.endIndex) {
            let next = found.upperBound < data.endIndex ? data[found.upperBound] : 0x20
            let continues = (next >= 0x30 && next <= 0x39) || (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
                || next == 0x2D || next == 0x5F || next == 0x2E
            if !continues { count += 1 }
            start = found.upperBound
        }
        return count
    }

    /// 끝부분에서 마지막 assistant 글 조각(최대 400자)
    static func lastText(in data: Data) -> String? {
        let marker = Data(#""type":"assistant""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if let last = texts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
                return last.count > 400 ? String(last.prefix(399)) + "…" : last
            }
        }
        return nil
    }
}
