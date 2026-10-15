import Foundation

public struct TranscriptSummary: Equatable {
    /// Claude 가 자동으로 붙인 제목
    public var aiTitle: String?
    /// 사용자가 붙인 이름(`claude -n`, /rename)
    public var customTitle: String?
    public var lastPrompt: String?
    public var modifiedAt: Date?

    public init(aiTitle: String? = nil, customTitle: String? = nil, lastPrompt: String? = nil, modifiedAt: Date? = nil) {
        self.aiTitle = aiTitle
        self.customTitle = customTitle
        self.lastPrompt = lastPrompt
        self.modifiedAt = modifiedAt
    }
}

/// 어디까지 읽었는지. 대화 파일은 뒤에 줄이 덧붙기만 하므로 다음에는 그 뒤만 읽는다.
public struct TranscriptCursor: Equatable {
    public var offset: UInt64
    public var summary: TranscriptSummary
}

/// ~/.claude/projects/<폴더>/<세션ID>.jsonl 에서 목록에 보여줄 정보만 뽑는다.
public enum TranscriptReader {
    static let tailBytes = 1 << 20
    static let fullScanLimit = 16 << 20

    public static func read(path: String) -> TranscriptSummary {
        update(path: path, cursor: nil).summary
    }

    /// cursor 가 있으면 그 뒤에 덧붙은 부분만 읽는다(진행 중인 세션을 자주 다시 읽어도 가볍게).
    /// 처음에는 파일 끝 1MB 를, 거기서 제목을 못 찾으면 한 번만 전체(16MB 이하)를 읽는다.
    public static func update(path: String, cursor: TranscriptCursor?) -> TranscriptCursor {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = UInt64((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        let modifiedAt = attrs?[.modificationDate] as? Date
        guard size > 0, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return TranscriptCursor(offset: 0, summary: TranscriptSummary(modifiedAt: modifiedAt))
        }
        defer { try? handle.close() }

        // 이어 읽기(파일이 줄었으면 바뀐 것으로 보고 처음부터)
        if var cursor, cursor.offset <= size {
            try? handle.seek(toOffset: cursor.offset)
            let consumed = apply(handle.readDataToEndOfFile(), to: &cursor.summary, skipFirstLine: false)
            cursor.offset += consumed
            cursor.summary.modifiedAt = modifiedAt
            return cursor
        }

        var summary = TranscriptSummary(modifiedAt: modifiedAt)
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let consumed = apply(handle.readDataToEndOfFile(), to: &summary, skipFirstLine: start > 0)
        if summary.aiTitle == nil && summary.customTitle == nil && start > 0 && size <= UInt64(fullScanLimit) {
            try? handle.seek(toOffset: 0)
            var full = TranscriptSummary()
            apply(handle.readData(ofLength: Int(start)), to: &full, skipFirstLine: false)
            summary.aiTitle = full.aiTitle
            summary.customTitle = full.customTitle
            summary.lastPrompt = summary.lastPrompt ?? full.lastPrompt
        }
        return TranscriptCursor(offset: start + consumed, summary: summary)
    }

    private static let markers: [(Data, String, WritableKeyPath<TranscriptSummary, String?>)] = [
        (Data(#""type":"ai-title""#.utf8), "aiTitle", \.aiTitle),
        (Data(#""type":"custom-title""#.utf8), "customTitle", \.customTitle),
        (Data(#""type":"last-prompt""#.utf8), "lastPrompt", \.lastPrompt),
    ]

    /// 끝까지 온전한 줄만 반영하고, 반영한 바이트 수를 돌려준다(쓰는 중인 마지막 줄은 다음에 다시 읽는다).
    @discardableResult
    static func apply(_ data: Data, to summary: inout TranscriptSummary, skipFirstLine: Bool) -> UInt64 {
        // 줄바꿈 없이 끝난 마지막 조각은 쓰는 중일 수 있다. 완전한 JSON 이면 반영하고, 아니면 다음에 다시 읽는다.
        var complete = data[...]
        if data.last != UInt8(ascii: "\n") {
            let tailStart = data.lastIndex(of: UInt8(ascii: "\n")).map { data.index(after: $0) } ?? data.startIndex
            if (try? JSONSerialization.jsonObject(with: Data(data[tailStart...]))) == nil {
                complete = data[data.startIndex..<tailStart]
            }
        }
        guard !complete.isEmpty else { return 0 }
        var lines = complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if skipFirstLine, !lines.isEmpty { lines.removeFirst() } // 중간부터 읽어 잘린 줄
        for line in lines {
            // 대부분의 줄은 대화 본문이다. 문자열로 바꾸지 않고 바이트로 표식만 찾는다.
            guard line.count < 64 * 1024,
                  let marker = markers.first(where: { line.range(of: $0.0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let value = object[marker.1] as? String, !value.isEmpty
            else { continue }
            summary[keyPath: marker.2] = value
        }
        return UInt64(complete.count)
    }

    /// 사용자가 처음 한 질문(이름 자동 짓기용). 파일 앞부분만 읽는다. 아직 질문이 없으면 nil.
    /// 명령(/clear 등)·시스템 표식·이어 하기 요약은 질문으로 치지 않는다.
    public static func firstPrompt(path: String, limit: Int = 2 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit)
        let marker = Data(#""type":"user""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "user",
                  object["isMeta"] as? Bool != true, object["isCompactSummary"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else { continue }
            var text: String?
            if let content = message["content"] as? String {
                text = content
            } else if let blocks = message["content"] as? [[String: Any]] {
                // 도구 결과 줄은 건너뛰고, 글 조각만 잇는다(그림을 붙인 질문)
                guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            guard let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
                  !prompt.hasPrefix("<"), !prompt.hasPrefix("Caveat:"),
                  !prompt.hasPrefix("This session is being continued")
            else { continue }
            return String(prompt.prefix(2_000))
        }
        return nil
    }

    /// hook 기록에 경로가 없을 때(앱 설치 전 세션 등) 세션 ID 로 대화 파일을 찾는다.
    public static func locate(sessionId: String, projectsDir: URL = Paths.claudeProjects) -> String? {
        guard SessionStore.isValidId(sessionId),
              let dirs = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)
        else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }
}

public enum GitInfo {
    /// 위로 올라가며 .git(폴더 또는 worktree 의 파일)이 있는 저장소 최상위 폴더를 찾는다.
    public static func repoRoot(at path: String) -> String? {
        var dir = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// .git/HEAD 를 직접 읽어 현재 브랜치를 얻는다(git 실행 없이). worktree 의 .git 파일도 따라간다.
    public static func branch(at path: String) -> String? {
        var dir = URL(fileURLWithPath: path, isDirectory: true)
        for _ in 0..<32 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue {
                    guard let text = try? String(contentsOf: git, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:")
                    else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: target, relativeTo: dir).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
                return String(trimmed.prefix(7)) // detached HEAD
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

public enum SessionNaming {
    /// 사람이 붙인 이름이 아니라 실행 도구가 기계적으로 붙인 이름인지.
    /// 예: claudec 의 "<폴더>@<브랜치>", "<폴더>-<HHMM>". 이런 이름은 첫 질문으로 지은 제목으로 바꿔 보여 준다.
    public static func isAutomatic(_ title: String, cwd: String) -> Bool {
        let folder = (cwd as NSString).lastPathComponent
        guard !folder.isEmpty, title.hasPrefix(folder) else { return false }
        let rest = title.dropFirst(folder.count)
        if rest.isEmpty { return true }
        if rest.hasPrefix("@"), !rest.contains(" ") { return true }
        if rest.hasPrefix("-"), rest.count == 5, rest.dropFirst().allSatisfy(\.isNumber) { return true }
        return false
    }

    /// 첫 질문을 제목 대신 잠깐 보여 줄 때: 첫 줄만, 너무 길면 자른다.
    public static func preview(of prompt: String, limit: Int = 28) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }
}
