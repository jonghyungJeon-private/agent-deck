import Foundation

/// 마크다운 한 조각: 글 + 꾸밈 표시. 하위 에이전트 글을 Claude Code 화면처럼 그리는 데 쓴다.
public struct MarkdownRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    /// # 제목(굵게 그린다)
    public var heading: Bool

    public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, heading: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.heading = heading
    }

    fileprivate var style: [Bool] { [bold, italic, code, heading] }
}

/// 직접 만든 작은 마크다운 해석기(정규식 없이 한 번 훑는다 — 항목 수백 개를 다시 그려도 느려지지 않게).
/// - **굵게** · *기울임* · _기울임_ · `코드` · # 제목(# 기호 제거) · ``` 코드 블록(울타리 줄은 빼고 안쪽은 그대로)
/// - 목록("- ")·표·링크는 해석하지 않고 글자 그대로 둔다. 짝이 맞지 않는 * _ ` 도 글자 그대로.
public enum AgentTranscriptMarkdown {
    public static func parse(_ source: String) -> [MarkdownRun] {
        var out: [MarkdownRun] = []
        var inFence = false
        var lastWasFence = false
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let isLast = index == lines.count - 1
            let newline = isLast ? "" : "\n"
            let line = String(rawLine)
            let stripped = line.drop(while: { $0 == " " })
            lastWasFence = false
            if isFenceLine(stripped) {
                inFence.toggle() // 울타리 줄(언어 이름 포함)은 줄바꿈까지 뺀다
                lastWasFence = true
                continue
            }
            if inFence {
                append(&out, MarkdownRun(line + newline))
                continue
            }
            if let heading = headingText(stripped) {
                inline(Array(heading), heading: true, into: &out)
            } else {
                inline(Array(line), heading: false, into: &out)
            }
            if !newline.isEmpty { append(&out, MarkdownRun(newline, heading: false)) }
        }
        // 마지막 줄이 울타리면 앞 줄의 줄바꿈이 끝에 남는다
        if lastWasFence, out.last?.text.hasSuffix("\n") == true {
            var last = out.removeLast()
            last.text.removeLast()
            if !last.text.isEmpty { out.append(last) }
        }
        return out
    }

    /// 울타리 줄인가: ``` 로 시작하고 그 줄에 ``` 가 한 번만 있다(```x``` 처럼 두 번이면 인라인 코드)
    private static func isFenceLine(_ line: Substring) -> Bool {
        guard line.hasPrefix("```") else { return false }
        return line.dropFirst(3).range(of: "```") == nil
    }

    /// "# 제목" → "제목"(# 1~6개 뒤에 공백)
    private static func headingText(_ line: Substring) -> Substring? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
            if hashes > 6 { return nil }
        }
        guard hashes > 0 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return rest.drop(while: { $0 == " " })
    }

    private static func append(_ out: inout [MarkdownRun], _ run: MarkdownRun) {
        guard !run.text.isEmpty else { return }
        if var last = out.last, last.style == run.style {
            last.text += run.text
            out[out.count - 1] = last
        } else {
            out.append(run)
        }
    }

    private static func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\n" }
    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// 한 줄 안의 꾸밈 해석(중첩: 굵게 안의 기울임 등)
    private static func inline(_ chars: [Character], heading: Bool, bold: Bool = false, italic: Bool = false, into out: inout [MarkdownRun]) {
        var literal = ""
        func flush() {
            append(&out, MarkdownRun(literal, bold: bold || heading, italic: italic, heading: heading))
            literal = ""
        }
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == "`" {
                if let span = codeSpan(chars, at: i) {
                    flush()
                    append(&out, MarkdownRun(String(chars[span.content]), bold: bold || heading, italic: italic, code: true, heading: heading))
                    i = span.end
                    continue
                }
                // 짝 없는 ` 는 같은 길이의 연속을 통째로 글자로(안쪽 일부만 짝으로 잡지 않게)
                while i < n, chars[i] == "`" { literal.append("`"); i += 1 }
                continue
            } else if c == "*" || c == "_" {
                let double = i + 1 < n && chars[i + 1] == c
                if double && c == "*" {
                    // **굵게**: 여는 ** 뒤는 공백이 아니고, 닫는 ** 앞도 공백이 아니다. *** 은 마지막 둘을 닫는 것으로 본다(closing 이 그 자리를 준다)
                    if i + 2 < n, !isSpace(chars[i + 2]), let close = closing(chars, from: i + 2, marker: "*", count: 2) {
                        flush()
                        inline(Array(chars[(i + 2)..<close]), heading: heading, bold: true, italic: italic, into: &out)
                        i = close + 2
                        continue
                    }
                } else if !double {
                    let opensWord = i == 0 || !isWord(chars[i - 1])
                    if i + 1 < n, !isSpace(chars[i + 1]), c == "*" || opensWord,
                       let close = closing(chars, from: i + 1, marker: c, count: 1),
                       c == "*" || close + 1 >= n || !isWord(chars[close + 1]) {
                        flush()
                        inline(Array(chars[(i + 1)..<close]), heading: heading, bold: bold, italic: true, into: &out)
                        i = close + 1
                        continue
                    }
                }
                if double {
                    // 짝 없는 ** · __ 는 둘 다 글자로
                    literal.append(c)
                    literal.append(c)
                    i += 2
                    continue
                }
            }
            literal.append(c)
            i += 1
        }
        flush()
    }

    /// i 에서 시작하는 ` 연속(k 개)과 같은 길이(k 개)로 닫히는 코드 조각: 안쪽 범위와 끝 다음 위치. 닫히지 않으면 nil.
    private static func codeSpan(_ chars: [Character], at i: Int) -> (content: Range<Int>, end: Int)? {
        let n = chars.count
        var k = 0
        while i + k < n, chars[i + k] == "`" { k += 1 }
        var j = i + k
        while j < n {
            guard chars[j] == "`" else { j += 1; continue }
            var run = 0
            while j + run < n, chars[j + run] == "`" { run += 1 }
            if run == k { return ((i + k)..<j, j + k) }
            j += run
        }
        return nil
    }

    /// 닫는 표시(marker 가 count 개 이어진 곳)의 위치. 앞 글자가 공백이면 닫는 표시가 아니다. 한 개짜리는 ** 의 일부를 건너뛴다.
    private static func closing(_ chars: [Character], from start: Int, marker: Character, count: Int) -> Int? {
        let n = chars.count
        var j = start
        while j < n {
            let c = chars[j]
            if c == "`" { // 코드 안의 표시는 건너뛴다
                if let span = codeSpan(chars, at: j) { j = span.end; continue }
                while j < n, chars[j] == "`" { j += 1 }
                continue
            }
            if c == marker {
                var run = 0
                while j + run < n, chars[j + run] == marker { run += 1 }
                if count == 2 {
                    if run >= 2, j > start, !isSpace(chars[j - 1]) { return j + run - 2 }
                } else if run == 1, !isSpace(chars[j - 1]) {
                    return j
                }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }
}
