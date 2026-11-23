import Foundation

/// 하위 에이전트 기록(agent-*.jsonl)에서 뽑은 한 줄 분량의 내용(읽기 전용 보기용)
public struct AgentTranscriptEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 에이전트에게 준 질문·지시(user 글)
        case prompt
        /// 에이전트가 남긴 글
        case text
        /// 에이전트가 부른 도구(이름 + 한 줄 요약)
        case tool
        /// 도구 결과(짧게)
        case result
    }

    public var kind: Kind
    public var text: String
    /// kind == .tool 일 때 도구 이름
    public var toolName: String?
    /// kind == .result 일 때 실패한 결과인지
    public var isError: Bool

    public init(kind: Kind, text: String, toolName: String? = nil, isError: Bool = false) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.isError = isError
    }
}

/// 기록 한 줄(JSON) → 보여 줄 내용. 모두 순수 함수.
public enum AgentTranscript {
    public static let textLimit = 2000
    public static let resultLimit = 300
    public static let summaryLimit = 200
    /// 이 크기를 넘는 줄은 읽지 않는다(api-request 같은 큰 줄 방어 — 보여 줄 user·assistant 줄은 이보다 작다)
    public static let lineLimit = 8 << 20

    private static let summaryKeys = ["description", "command", "file_path", "pattern", "url", "prompt", "code"]
    private static let skippedPrefixes = ["{\"type\":\"api-request", "{\"type\":\"attachment"].map { Data($0.utf8) }
    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// 줄 하나를 내용으로. user·assistant 줄만 읽고 나머지(api-request·attachment 등)는 JSON 으로 풀지 않고 버린다.
    public static func entries(fromLine line: Data) -> [AgentTranscriptEntry] {
        guard !line.isEmpty, line.count <= lineLimit else { return [] }
        for prefix in skippedPrefixes where line.starts(with: prefix) { return [] }
        guard line.range(of: userMarker) != nil || line.range(of: assistantMarker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              let message = object["message"] as? [String: Any]
        else { return [] }
        var out: [AgentTranscriptEntry] = []
        if let string = message["content"] as? String {
            let text = capped(string.trimmingCharacters(in: .whitespacesAndNewlines), textLimit)
            if !text.isEmpty { out.append(AgentTranscriptEntry(kind: type == "user" ? .prompt : .text, text: text)) }
            return out
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = capped(((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), textLimit)
                if !text.isEmpty { out.append(AgentTranscriptEntry(kind: type == "user" ? .prompt : .text, text: text)) }
            case "tool_use" where type == "assistant":
                let name = (block["name"] as? String) ?? "tool"
                let summary = toolSummary(block["input"] as? [String: Any] ?? [:])
                out.append(AgentTranscriptEntry(kind: .tool, text: summary, toolName: name))
            case "tool_result" where type == "user":
                let text = capped(collapsed(resultText(block["content"])), resultLimit)
                let isError = (block["is_error"] as? Bool) == true
                // 빈 결과(REPL·백그라운드로 띄운 도구 등)는 줄만 늘리므로 뺀다. 실패는 비어 있어도 남긴다.
                if text.isEmpty && !isError { break }
                out.append(AgentTranscriptEntry(kind: .result, text: text, isError: isError))
            default:
                break // thinking·image 등은 건너뛴다
            }
        }
        return out
    }

    /// 도구 입력의 한 줄 요약: description · command · file_path · pattern · url · prompt · code 중 처음 있는 것의 첫 비지 않은 줄.
    /// 아무것도 없으면 입력 JSON 앞부분.
    public static func toolSummary(_ input: [String: Any]) -> String {
        for key in summaryKeys {
            guard let value = input[key] as? String else { continue }
            if let line = value.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return capped(line, summaryLimit)
            }
        }
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return capped(collapsed(json), summaryLimit)
    }

    private static func resultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        }
        return ""
    }

    /// 줄바꿈·연속 공백을 공백 하나로
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func capped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// 하위 에이전트 기록 파일의 끝을 따라 읽는다. 처음엔 끝 initialBytes 만, 그다음은 늘어난 바이트만 읽는다.
/// 한 곳(보이는 화면)에서만 쓴다(스레드 안전하지 않음).
public final class AgentTranscriptTail {
    /// poll() 결과
    public enum Change: Equatable {
        /// 달라진 게 없다
        case none
        /// 항목이 뒤에 붙었다(그대로 이어 그리면 된다)
        case appended([AgentTranscriptEntry])
        /// 처음 읽음·파일이 줄어 다시 읽음·오래된 항목이 밀려남 — entries 전체를 다시 그려야 한다
        case reset

        public var changed: Bool { self != .none }
    }

    public let path: String
    public let initialBytes: Int
    /// 남기는 항목 수. 이어 읽는 동안은 이것의 1.25배까지 늘었다가 한꺼번에 줄어든다.
    public let maxEntries: Int
    public private(set) var entries: [AgentTranscriptEntry] = []
    /// 마지막으로 열어 본 결과 파일이 없었는지
    public private(set) var isMissing = false

    private var started = false
    private var offset: UInt64 = 0
    /// 아직 줄바꿈이 오지 않은 끝 줄
    private var pending = Data()
    /// 끝 줄이 이만큼 길어지면 버린다(줄바꿈 없이 커지는 파일 방어)
    private static let pendingLimit = 32 << 20

    public init(path: String, initialBytes: Int = 512 << 10, maxEntries: Int = 400) {
        self.path = path
        self.initialBytes = initialBytes
        self.maxEntries = maxEntries
    }

    @discardableResult
    public func poll() -> Change {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            let changed = !isMissing || !entries.isEmpty
            isMissing = true
            if !entries.isEmpty { entries = [] }
            started = false
            offset = 0
            pending = Data()
            return changed ? .reset : .none
        }
        defer { try? handle.close() }
        isMissing = false
        guard let size = try? handle.seekToEnd() else { return .none }
        var forceReset = false
        if started, size < offset { // 파일이 줄었다(다시 쓰임): 처음부터 다시
            forceReset = true
            started = false
            entries = []
            pending = Data()
        }
        var data: Data
        if !started {
            let initial = UInt64(max(initialBytes, 1))
            let start = size > initial ? size - initial : 0
            // 시작 바로 앞 한 바이트까지 읽어 줄 중간에서 시작했는지 본다
            let from = start > 0 ? start - 1 : 0
            try? handle.seek(toOffset: from)
            data = handle.readDataToEndOfFile()
            if start > 0, !data.isEmpty {
                if data.first == 0x0A {
                    data.removeFirst()
                } else if let newline = data.firstIndex(of: 0x0A) {
                    data.removeSubrange(data.startIndex...newline) // 잘린 첫 줄은 버린다
                } else {
                    data = Data()
                }
            }
            offset = handle.offsetInFile
            started = true
            forceReset = true
        } else {
            guard size > offset else { return .none }
            try? handle.seek(toOffset: offset)
            data = handle.readDataToEndOfFile()
            offset = handle.offsetInFile
        }
        pending.append(data)
        var fresh: [AgentTranscriptEntry] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            fresh += AgentTranscript.entries(fromLine: Data(pending[lineStart..<newline]))
            lineStart = pending.index(after: newline)
        }
        pending = Data(pending[lineStart...])
        if pending.count > Self.pendingLimit { pending = Data() }
        entries += fresh
        // 넘칠 때마다 1개씩 밀면 그때마다 전체를 다시 그리게 된다: 상한의 1/4 만큼 더 쌓이면 한꺼번에 상한까지 줄인다
        // (처음 읽을 때는 바로 상한까지)
        var trimmed = false
        if entries.count > (forceReset ? maxEntries : maxEntries + max(1, maxEntries / 4)) {
            entries.removeFirst(entries.count - maxEntries)
            trimmed = true
        }
        if forceReset { return entries.isEmpty && !trimmed && fresh.isEmpty ? .none : .reset }
        if trimmed { return .reset }
        return fresh.isEmpty ? .none : .appended(fresh)
    }
}
