import Foundation

/// 한 칸의 에이전트가 이번 턴에 낸 마지막 답글을 대화 기록에서 읽는다(`agentdeck ask`).
/// 화면을 긁는 것보다 정확하다 — 색·줄바꿈·도구 출력이 섞이지 않고 긴 답도 잘리지 않는다.
public enum TurnReply {
    /// 읽을 최대 바이트(턴이 아주 길어도 끝에서 이만큼만)
    public static let maxBytes = 16 << 20

    /// 기록의 크기(보내기 전 기준점 — 이 뒤에 덧붙은 것만 이번 턴이다). 파일이 없으면 0.
    public static func size(of path: String?) -> UInt64 {
        guard let path, let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// 기준점 뒤에 덧붙은 부분을 읽는다
    public static func read(path: String, from offset: UInt64) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard end > offset else { return Data() }
        let start = max(offset, end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        try? handle.seek(toOffset: start)
        return handle.readDataToEndOfFile()
    }

    /// claude 기록(jsonl)에서 마지막 assistant 글. 한 답이 여러 줄(글 조각마다 한 줄, 같은 message.id)로 나뉘어 적히므로 이어 붙이고,
    /// 도구를 쓰는 사이사이의 글(예: "확인해 보겠습니다")은 마지막 답이 아니다. 사용자 질문 줄이 나오면 그 앞 답은 버린다
    /// (이번 턴에 답이 없으면 지난 턴 답을 돌려주지 않는다). 하위 에이전트(isSidechain) 줄은 건너뛴다. 글이 없으면 nil.
    public static func lastClaudeText(in data: Data) -> String? {
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        let userMarker = Data(#""type":"user""#.utf8)
        var currentId: String?
        var current: [String] = []
        var seenAny = false
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let isAssistant = line.range(of: assistantMarker) != nil
            guard isAssistant || line.range(of: userMarker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else { continue }
            if type == "user" {
                if isPrompt(message), object["isMeta"] as? Bool != true {
                    current = []
                    currentId = nil
                    seenAny = false
                }
                continue
            }
            guard type == "assistant" else { continue }
            let texts = blocks(message).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            let id = message["id"] as? String
            if let id, id == currentId, seenAny {
                current += texts
            } else {
                current = texts
                currentId = id
            }
            seenAny = true
        }
        let text = current.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private static func blocks(_ message: [String: Any]) -> [[String: Any]] {
        if let blocks = message["content"] as? [[String: Any]] { return blocks }
        if let text = message["content"] as? String { return [["type": "text", "text": text]] }
        return []
    }

    /// 사용자가 보낸 질문인가(도구 결과만 든 줄은 아니다)
    private static func isPrompt(_ message: [String: Any]) -> Bool {
        if message["content"] is String { return true }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// codex rollout(jsonl)에서 마지막 assistant 메시지. 사용자 메시지가 나오면 그 앞 답은 버린다.
    public static func lastCodexText(in data: Data) -> String? {
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message"
            else { continue }
            let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch payload["role"] as? String {
            case "user": if !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md") { last = nil }
            case "assistant": if !text.isEmpty { last = text }
            default: break
            }
        }
        return last
    }
}
