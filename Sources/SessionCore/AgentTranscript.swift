import Foundation

/// 하위 에이전트 기록(agent-*.jsonl)에서 뽑은 한 줄 분량의 내용(읽기 전용 보기용)
public struct AgentTranscriptEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 에이전트에게 준 질문·지시(user 글)
        case prompt
        /// 에이전트가 남긴 글(마크다운)
        case text
        /// 에이전트가 부른 도구: toolName(표시 이름) + text(괄호 안 인자)
        case tool
        /// 도구 결과(몇 줄로 줄인 글)
        case result
        /// 생각 블록(내용은 보이지 않고 한 줄 표시만)
        case thinking
    }

    public var kind: Kind
    public var text: String
    /// kind == .tool 일 때 Claude Code 식 표시 이름(Read·Update·Search·… — "이름(인자)" 의 이름)
    public var toolName: String?
    /// kind == .result 일 때 실패한 결과인지
    public var isError: Bool
    /// .tool 은 tool_use 의 id, .result 는 어느 tool_use 의 결과인지(⏺ 색을 바꿀 때 짝을 찾는 열쇠)
    public var toolUseId: String?
    /// kind == .result 일 때 굵게 그릴 부분(text 안의 UTF-16 범위 — "Read **12** lines" 의 숫자)
    public var boldRanges: [NSRange]

    public init(kind: Kind, text: String, toolName: String? = nil, isError: Bool = false,
                toolUseId: String? = nil, boldRanges: [NSRange] = []) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.isError = isError
        self.toolUseId = toolUseId
        self.boldRanges = boldRanges
    }

    /// 화면에 그리는 항목인지. 내용 없는 성공 결과는 그리지 않는다(도구의 ⏺ 색을 바꾸는 데만 쓴다).
    public var isVisible: Bool { kind != .result || !text.isEmpty || isError }
}

/// 기록 한 줄(JSON) → 보여 줄 내용. 모두 순수 함수.
public enum AgentTranscript {
    public static let textLimit = 2000
    /// 결과 한 줄의 글자 상한
    public static let resultLimit = 300
    /// 결과에서 보여 주는 줄 수(나머지는 "… +N lines")
    public static let resultLines = 3
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
        let cwd = (object["cwd"] as? String) ?? ""
        var out: [AgentTranscriptEntry] = []
        if let string = message["content"] as? String {
            let text = capped(string.trimmingCharacters(in: .whitespacesAndNewlines), textLimit)
            if !text.isEmpty { out.append(AgentTranscriptEntry(kind: type == "user" ? .prompt : .text, text: text)) }
            return out
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        // 줄 맨 위 "toolUseResult" 는 결과가 하나일 때만 그 결과의 구조다
        let resultCount = type == "user" ? blocks.filter { ($0["type"] as? String) == "tool_result" }.count : 0
        let structured = resultCount == 1 ? object["toolUseResult"] as? [String: Any] : nil
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = capped(((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), textLimit)
                if !text.isEmpty { out.append(AgentTranscriptEntry(kind: type == "user" ? .prompt : .text, text: text)) }
            case "thinking" where type == "assistant", "redacted_thinking" where type == "assistant":
                out.append(AgentTranscriptEntry(kind: .thinking, text: ""))
            case "tool_use" where type == "assistant":
                let (name, arguments) = toolDisplay(name: (block["name"] as? String) ?? "tool",
                                                    input: block["input"] as? [String: Any] ?? [:], cwd: cwd)
                out.append(AgentTranscriptEntry(kind: .tool, text: arguments, toolName: name, toolUseId: block["id"] as? String))
            case "tool_result" where type == "user":
                let isError = (block["is_error"] as? Bool) == true
                let content = resultText(block["content"])
                let (text, bold) = isError ? (foldedLines(errorText(content)), []) : resultSummary(structured: structured, content: content, cwd: cwd)
                // 내용 없는 성공 결과(REPL·백그라운드로 띄운 도구 등)는 항목으로 남기되 그리지 않는다(isVisible) — ⏺ 색은 바꿔야 하므로.
                out.append(AgentTranscriptEntry(kind: .result, text: text, isError: isError,
                                                toolUseId: block["tool_use_id"] as? String, boldRanges: bold))
            default:
                break // image 등은 건너뛴다
            }
        }
        return out
    }

    // MARK: - 도구 호출

    /// 도구 호출 → Claude Code 식 (표시 이름, 괄호 안 인자). 인자가 비면 괄호를 그리지 않는다.
    public static func toolDisplay(name: String, input: [String: Any], cwd: String) -> (name: String, arguments: String) {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func path(_ key: String) -> String? { string(key).map { relativePath($0, cwd: cwd) } }
        func firstLine(_ value: String?) -> String? {
            guard let value else { return nil }
            let lines = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = lines.first else { return nil }
            return capped(lines.count > 1 && !first.hasSuffix("…") ? first + "…" : first, summaryLimit)
        }
        switch name {
        case "Read": return ("Read", path("file_path").map { capped($0, summaryLimit) } ?? "")
        case "Write": return ("Write", path("file_path").map { capped($0, summaryLimit) } ?? "")
        case "Edit", "MultiEdit": return ("Update", path("file_path").map { capped($0, summaryLimit) } ?? "")
        case "NotebookEdit": return ("Update", path("notebook_path").map { capped($0, summaryLimit) } ?? "")
        case "Bash": return ("Bash", firstLine(string("command")) ?? "")
        case "Grep", "Glob":
            var parts: [String] = []
            if let pattern = string("pattern") { parts.append("pattern: \(quoted(pattern))") }
            if let target = path("path") { parts.append("path: \(quoted(target))") }
            return ("Search", capped(parts.joined(separator: ", "), summaryLimit))
        case "WebFetch": return ("Fetch", capped(string("url") ?? "", summaryLimit))
        case "WebSearch": return ("Web Search", string("query").map { quoted($0) } ?? "")
        case "Task", "Agent":
            let kind = string("subagent_type")
            return (kind ?? "Task", firstLine(string("description")) ?? "")
        case "TodoWrite": return ("Update Todos", "")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 {
                    return ("\(parts[0]) - \(parts.dropFirst().joined(separator: "__")) (MCP)", keyValues(input, limit: Int.max))
                }
            }
            return (name, toolSummary(input))
        }
    }

    /// 도구 입력의 한 줄 요약: description · command · file_path · pattern · url · prompt · code 중 처음 있는 것의 첫 비지 않은 줄.
    /// 아무것도 없으면 key: "value" 앞 두 개.
    public static func toolSummary(_ input: [String: Any]) -> String {
        for key in summaryKeys {
            guard let value = input[key] as? String else { continue }
            if let line = value.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                return capped(line, summaryLimit)
            }
        }
        return keyValues(input, limit: 2)
    }

    /// key: "value", key: "value" (키 이름순 — 사전 순서는 정해져 있지 않으므로)
    private static func keyValues(_ input: [String: Any], limit: Int) -> String {
        let parts = input.keys.sorted().prefix(limit).map { "\($0): \(valueText(input[$0]!))" }
        return capped(parts.joined(separator: ", "), summaryLimit)
    }

    private static func valueText(_ value: Any) -> String {
        if let string = value as? String { return quoted(string) }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { return capped(json, 60) }
        return "\(value)"
    }

    private static func quoted(_ text: String) -> String { "\"" + capped(collapsed(text), 80) + "\"" }

    /// cwd 밖이 아니면 cwd 기준 상대 경로, 밖이면 그대로(절대 경로). cwd 자신은 "."
    public static func relativePath(_ path: String, cwd: String) -> String {
        guard !cwd.isEmpty, path.hasPrefix("/") else { return path }
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if path == base { return "." }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return path
    }

    // MARK: - 도구 결과

    /// 결과 글(과 굵게 그릴 범위). 줄 맨 위 toolUseResult 구조를 먼저 보고, 알아볼 수 없으면 tool_result 의 글을 줄여 쓴다.
    public static func resultSummary(structured: [String: Any]?, content: String, cwd: String) -> (text: String, bold: [NSRange]) {
        if let s = structured {
            if let file = s["file"] as? [String: Any], let lines = int(file["numLines"]) {
                return counted("Read ", lines, lines == 1 ? " line" : " lines")
            }
            if (s["type"] as? String) == "create", let created = s["content"] as? String {
                let lines = created.isEmpty ? 0 : created.split(separator: "\n", omittingEmptySubsequences: false).count - (created.hasSuffix("\n") ? 1 : 0)
                let target = relativePath((s["filePath"] as? String) ?? "", cwd: cwd)
                return counted("Wrote ", lines, (lines == 1 ? " line" : " lines") + " to " + target)
            }
            if let patch = s["structuredPatch"] as? [[String: Any]] {
                var added = 0, removed = 0
                for hunk in patch {
                    for line in (hunk["lines"] as? [String]) ?? [] {
                        if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                    }
                }
                let target = relativePath((s["filePath"] as? String) ?? "", cwd: cwd)
                let head = "Updated \(target) with "
                let first = "\(added)", second = "\(removed)"
                let text = head + first + (added == 1 ? " addition" : " additions") + " and " + second + (removed == 1 ? " removal" : " removals")
                let firstRange = NSRange(location: (head as NSString).length, length: (first as NSString).length)
                let secondLocation = firstRange.location + firstRange.length + (added == 1 ? " addition and " : " additions and ").utf16.count
                return (text, [firstRange, NSRange(location: secondLocation, length: (second as NSString).length)])
            }
            if let files = int(s["numFiles"]) {
                if (s["mode"] as? String) == "content", let lines = int(s["numLines"]) {
                    return lines == 0 ? ("No matches found", []) : counted("Found ", lines, lines == 1 ? " line" : " lines")
                }
                return files == 0 ? ("No files found", []) : counted("Found ", files, files == 1 ? " file" : " files")
            }
            if s["stdout"] is String || s["stderr"] is String {
                if (s["interrupted"] as? Bool) == true { return ("Interrupted by user", []) }
                let out = (s["stdout"] as? String) ?? "", err = (s["stderr"] as? String) ?? ""
                let shown = !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : err
                let folded = foldedLines(shown)
                return (folded.isEmpty ? "(No content)" : folded, [])
            }
            if let code = int(s["code"]), s["codeText"] is String || s["bytes"] != nil {
                let size = byteText(int(s["bytes"]) ?? 0)
                let status = ((s["codeText"] as? String) ?? "").isEmpty ? "\(code)" : "\(code) \(s["codeText"] as! String)"
                return ("Received \(size) (\(status))", [])
            }
        }
        return (foldedLines(content), [])
    }

    /// "<앞><숫자><뒤>" 에서 숫자를 굵게
    private static func counted(_ before: String, _ number: Int, _ after: String) -> (String, [NSRange]) {
        let digits = "\(number)"
        return (before + digits + after, [NSRange(location: (before as NSString).length, length: digits.utf16.count)])
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func byteText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1fKB", kb) }
        return String(format: "%.1fMB", kb / 1024)
    }

    /// 여러 줄 글은 앞 resultLines 줄만(줄마다 resultLimit 자) + "… +N lines". 끝의 빈 줄은 센 줄에 넣지 않는다.
    public static func foldedLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        guard !lines.isEmpty else { return "" }
        var shown = lines.prefix(resultLines).map { capped(String($0), resultLimit) }
        if lines.count > resultLines { shown.append("… +\(lines.count - resultLines) lines") }
        return shown.joined(separator: "\n")
    }

    /// <tool_use_error>…</tool_use_error> 껍데기를 벗긴다
    private static func errorText(_ content: String) -> String {
        let open = "<tool_use_error>", close = "</tool_use_error>"
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(open) { text.removeFirst(open.count) }
        if text.hasSuffix(close) { text.removeLast(close.count) }
        return text
    }

    private static func resultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
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
    /// 세는 대상은 thinking 과 화면에 안 그리는 결과(isVisible == false)까지 모든 항목이라, 실제로 보이는 항목은 이보다 적을 수 있다.
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
        var shrank = false
        if started, size < offset { // 파일이 줄었다(다시 쓰임): 처음부터 다시
            forceReset = true
            shrank = true
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
        // 파일이 줄어 비웠으면 새 줄이 없어도 .reset — 화면에 남은 옛 글을 지워야 한다
        if forceReset { return entries.isEmpty && !trimmed && fresh.isEmpty && !shrank ? .none : .reset }
        if trimmed { return .reset }
        return fresh.isEmpty ? .none : .appended(fresh)
    }
}
