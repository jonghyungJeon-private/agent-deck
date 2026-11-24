import Foundation
import SessionCore
import XCTest

final class AgentTranscriptTests: XCTestCase {
    func testTailResetsWhenFileShrinksToNothing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shrink-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"# + "\n"
        try Data(line.utf8).write(to: url)
        let tail = AgentTranscriptTail(path: url.path)
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.count, 1)
        try Data().write(to: url) // 다시 쓰여 비었다
        XCTAssertEqual(tail.poll(), .reset, "화면의 옛 글을 지우도록 reset")
        XCTAssertTrue(tail.entries.isEmpty)
        XCTAssertEqual(tail.poll(), .none)
    }

    func testTailResetsWhenFileShrinksButKeepsLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shrink2-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ t: String) -> String { #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":""# + t + #""}]}}"# + "\n" }
        try Data((line("one") + line("two")).utf8).write(to: url)
        let tail = AgentTranscriptTail(path: url.path)
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.count, 2)
        try Data(line("x").utf8).write(to: url)
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.map(\.text), ["x"])
    }

    var dir: URL!
    var path: String { dir.appendingPathComponent("agent-x.jsonl").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func userLine(_ text: String) -> String { #"{"type":"user","message":{"role":"user","content":\#(json(text))}}"# }
    func assistantLine(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":\#(json(text))}]}}"#
    }
    func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }
    func write(_ text: String) { try! Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    func append(_ text: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    func testPartialLineAcrossTwoPolls() {
        let line = assistantLine("hello world")
        write(userLine("go") + "\n" + String(line.prefix(30)))
        let tail = AgentTranscriptTail(path: path)
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.map(\.kind), [.prompt])
        append(String(line.dropFirst(30)))
        XCTAssertEqual(tail.poll(), .none) // 줄바꿈이 아직 없다
        append("\n")
        XCTAssertEqual(tail.poll(), .appended([AgentTranscriptEntry(kind: .text, text: "hello world")]))
        XCTAssertEqual(tail.entries.map(\.text), ["go", "hello world"])
        XCTAssertEqual(tail.poll(), .none)
    }

    func testIgnoresApiRequestAndAttachmentLines() {
        let big = String(repeating: "x", count: 50_000)
        write([
            #"{"type":"api-request","body":{"type":"user","text":"\#(big)"}}"#,
            #"{"type":"api-request-blob","data":"\#(big)"}"#,
            #"{"type":"api-request-shape","a":1}"#,
            #"{"type":"attachment","attachment":{"type":"assistant"}}"#,
            #"{"note":"no type","x":{"type":"user"}}"#,
            userLine("real"),
        ].joined(separator: "\n") + "\n")
        let tail = AgentTranscriptTail(path: path)
        tail.poll()
        XCTAssertEqual(tail.entries.map(\.text), ["real"])
    }

    func testInitialTailStartingMidLineDropsPartialFirstLine() {
        let lines = (0..<20).map { assistantLine("message-\($0)-" + String(repeating: "a", count: 40)) }
        write(lines.joined(separator: "\n") + "\n")
        let tail = AgentTranscriptTail(path: path, initialBytes: 600)
        tail.poll()
        XCTAssertFalse(tail.entries.isEmpty)
        XCTAssertLessThan(tail.entries.count, 20)
        XCTAssertTrue(tail.entries.last!.text.hasPrefix("message-19-"))
        // 잘린 줄이 섞이지 않는다: 모든 항목이 온전하다
        XCTAssertTrue(tail.entries.allSatisfy { $0.text.range(of: #"^message-\d+-a{40}$"#, options: .regularExpression) != nil })
    }

    func testInitialTailStartingExactlyAtLineBoundaryKeepsLine() {
        let a = assistantLine("first"), b = assistantLine("second")
        write(a + "\n" + b + "\n")
        let tail = AgentTranscriptTail(path: path, initialBytes: b.utf8.count + 1)
        tail.poll()
        XCTAssertEqual(tail.entries.map(\.text), ["second"])
    }

    func testTruncationResetsAndRereads() {
        write(userLine("one") + "\n" + userLine("two") + "\n")
        let tail = AgentTranscriptTail(path: path)
        tail.poll()
        XCTAssertEqual(tail.entries.count, 2)
        write(userLine("n") + "\n")
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.map(\.text), ["n"])
    }

    func testMaxEntriesDropsOldestAndReportsReset() {
        write((0..<5).map { userLine("m\($0)") }.joined(separator: "\n") + "\n")
        let tail = AgentTranscriptTail(path: path, maxEntries: 4)
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.map(\.text), ["m1", "m2", "m3", "m4"])
        // 상한 + 1/4(=1)까지는 이어 붙이기만 한다(매번 전체를 다시 그리지 않게)
        append(userLine("m5") + "\n")
        XCTAssertEqual(tail.poll(), .appended([AgentTranscriptEntry(kind: .prompt, text: "m5")]))
        XCTAssertEqual(tail.entries.count, 5)
        // 그보다 넘치면 한꺼번에 상한까지 줄이고 다시 그린다
        append(userLine("m6") + "\n")
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertEqual(tail.entries.map(\.text), ["m3", "m4", "m5", "m6"])
    }

    func testMissingFile() {
        let tail = AgentTranscriptTail(path: path)
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertTrue(tail.isMissing)
        XCTAssertEqual(tail.poll(), .none)
        write(userLine("late") + "\n")
        XCTAssertEqual(tail.poll(), .reset)
        XCTAssertFalse(tail.isMissing)
        XCTAssertEqual(tail.entries.map(\.text), ["late"])
    }

    func testEntryKindsAndCaps() {
        let long = String(repeating: "가", count: 3000)
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"\#(long)"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la\nmore"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"1","content":"a\n\nb  c","is_error":true},{"type":"tool_result","tool_use_id":"2","content":[{"type":"text","text":"ok"}]}]}}"#,
        ]
        let entries = lines.flatMap { AgentTranscript.entries(fromLine: Data($0.utf8)) }
        XCTAssertEqual(entries.map(\.kind), [.thinking, .text, .tool, .result, .result])
        XCTAssertEqual(entries[0].text, "")
        XCTAssertEqual(entries[1].text.count, AgentTranscript.textLimit)
        XCTAssertTrue(entries[1].text.hasSuffix("…"))
        XCTAssertEqual(entries[2].toolName, "Bash")
        XCTAssertEqual(entries[2].text, "ls -la…") // 여러 줄 명령은 첫 줄 + …
        XCTAssertEqual(entries[3].text, "a\n\nb  c")
        XCTAssertTrue(entries[3].isError)
        XCTAssertEqual(entries[4].text, "ok")
        XCTAssertFalse(entries[4].isError)
    }

    func testToolSummaryPicksFirstPresentKey() {
        XCTAssertEqual(AgentTranscript.toolSummary(["command": "ls", "description": "list files"]), "list files")
        XCTAssertEqual(AgentTranscript.toolSummary(["description": "  ", "command": "\n\nrun it\nnext"]), "run it")
        XCTAssertEqual(AgentTranscript.toolSummary(["file_path": "/a/b.swift", "pattern": "x"]), "/a/b.swift")
        XCTAssertEqual(AgentTranscript.toolSummary(["pattern": "foo.*"]), "foo.*")
        XCTAssertEqual(AgentTranscript.toolSummary(["url": "https://x.y"]), "https://x.y")
        XCTAssertEqual(AgentTranscript.toolSummary(["prompt": "do it"]), "do it")
        XCTAssertEqual(AgentTranscript.toolSummary(["code": "let a = 1\nlet b"]), "let a = 1")
        XCTAssertEqual(AgentTranscript.toolSummary(["b": 2, "a": "x", "c": true]), #"a: "x", b: 2"#)
        XCTAssertEqual(AgentTranscript.toolSummary([:]), "")
        XCTAssertEqual(AgentTranscript.toolSummary(["command": String(repeating: "z", count: 500)]).count, AgentTranscript.summaryLimit)
    }

    func testStringContentIsPrompt() {
        let entries = AgentTranscript.entries(fromLine: Data(userLine("do the thing").utf8))
        XCTAssertEqual(entries, [AgentTranscriptEntry(kind: .prompt, text: "do the thing")])
    }

    func testEmptyResultsAreSkippedButEmptyErrorsKept() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":""},{"type":"tool_result","tool_use_id":"b","content":[],"is_error":true},{"type":"tool_result","tool_use_id":"c","content":"ok"}]}}"#
        let entries = AgentTranscript.entries(fromLine: Data(line.utf8))
        // 내용 없는 성공 결과도 항목으로 남지만(⏺ 색용) 그리지 않는다
        XCTAssertEqual(entries.map(\.text), ["", "", "ok"])
        XCTAssertEqual(entries.map(\.isError), [false, true, false])
        XCTAssertEqual(entries.map(\.isVisible), [false, true, true])
        XCTAssertEqual(entries.map(\.toolUseId), ["a", "b", "c"])
    }

    // MARK: - Claude Code 식 표시

    private func tool(_ name: String, _ input: [String: Any], cwd: String = "/w/proj") -> (name: String, arguments: String) {
        AgentTranscript.toolDisplay(name: name, input: input, cwd: cwd)
    }

    func testToolDisplayNames() {
        XCTAssertTrue(tool("Read", ["file_path": "/w/proj/src/a.swift"]) == ("Read", "src/a.swift"))
        XCTAssertTrue(tool("Write", ["file_path": "/w/proj/b.txt"]) == ("Write", "b.txt"))
        XCTAssertTrue(tool("Edit", ["file_path": "/w/proj/c.txt"]) == ("Update", "c.txt"))
        XCTAssertTrue(tool("MultiEdit", ["file_path": "/w/proj/d.txt"]) == ("Update", "d.txt"))
        XCTAssertTrue(tool("Bash", ["command": "ls -la"]) == ("Bash", "ls -la"))
        XCTAssertTrue(tool("Bash", ["command": "echo a\necho b"]) == ("Bash", "echo a…"))
        XCTAssertTrue(tool("Grep", ["pattern": "foo", "path": "/w/proj/src"]) == ("Search", #"pattern: "foo", path: "src""#))
        XCTAssertTrue(tool("Grep", ["pattern": "foo"]) == ("Search", #"pattern: "foo""#))
        XCTAssertTrue(tool("Glob", ["pattern": "**/*.swift", "path": "/other"]) == ("Search", #"pattern: "**/*.swift", path: "/other""#))
        XCTAssertTrue(tool("WebFetch", ["url": "https://x.y/z"]) == ("Fetch", "https://x.y/z"))
        XCTAssertTrue(tool("WebSearch", ["query": "swift ui"]) == ("Web Search", #""swift ui""#))
        XCTAssertTrue(tool("Task", ["subagent_type": "Explore", "description": "find it"]) == ("Explore", "find it"))
        XCTAssertTrue(tool("Agent", ["description": "do it"]) == ("Task", "do it"))
        XCTAssertTrue(tool("TodoWrite", ["todos": []]) == ("Update Todos", ""))
        XCTAssertTrue(tool("mcp__slack__send_message", ["channel": "C1", "n": 2]) == ("slack - send_message (MCP)", #"channel: "C1", n: 2"#))
        XCTAssertTrue(tool("Custom", ["command": "run", "x": "y"]) == ("Custom", "run"))
        XCTAssertTrue(tool("Custom", ["b": "2", "a": "1", "c": "3"]) == ("Custom", #"a: "1", b: "2""#))
        XCTAssertTrue(tool("Custom", [:]) == ("Custom", ""))
    }

    func testRelativePath() {
        XCTAssertEqual(AgentTranscript.relativePath("/w/proj/a/b.txt", cwd: "/w/proj"), "a/b.txt")
        XCTAssertEqual(AgentTranscript.relativePath("/w/proj/a/b.txt", cwd: "/w/proj/"), "a/b.txt")
        XCTAssertEqual(AgentTranscript.relativePath("/w/proj", cwd: "/w/proj"), ".")
        XCTAssertEqual(AgentTranscript.relativePath("/w/project/a", cwd: "/w/proj"), "/w/project/a") // 접두사만 같은 다른 폴더
        XCTAssertEqual(AgentTranscript.relativePath("/etc/hosts", cwd: "/w/proj"), "/etc/hosts")
        XCTAssertEqual(AgentTranscript.relativePath("/etc/hosts", cwd: ""), "/etc/hosts")
        XCTAssertEqual(AgentTranscript.relativePath("rel/x", cwd: "/w/proj"), "rel/x")
    }

    private func toolLine(id: String, name: String, input: String, cwd: String = "/w/proj") -> String {
        #"{"type":"assistant","cwd":"\#(cwd)","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func resultLine(id: String, content: String = "", structured: String? = nil, isError: Bool = false, cwd: String = "/w/proj") -> String {
        let structuredPart = structured.map { #","toolUseResult":\#($0)"# } ?? ""
        return #"{"type":"user","cwd":"\#(cwd)","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":\#(json(content)),"is_error":\#(isError)}]}\#(structuredPart)}"#
    }

    private func result(_ line: String) -> AgentTranscriptEntry { AgentTranscript.entries(fromLine: Data(line.utf8))[0] }

    func testToolEntryCarriesIdAndRelativePath() {
        let entry = AgentTranscript.entries(fromLine: Data(toolLine(id: "t1", name: "Read", input: #"{"file_path":"/w/proj/x/y.swift"}"#).utf8))[0]
        XCTAssertEqual(entry.kind, .tool)
        XCTAssertEqual(entry.toolName, "Read")
        XCTAssertEqual(entry.text, "x/y.swift")
        XCTAssertEqual(entry.toolUseId, "t1")
        XCTAssertEqual(result(resultLine(id: "t1", content: "x")).toolUseId, "t1")
    }

    func testResultReadLines() {
        let entry = result(resultLine(id: "1", content: "1\ta", structured: #"{"type":"text","file":{"filePath":"/w/proj/a","content":"a","numLines":12,"startLine":1,"totalLines":12}}"#))
        XCTAssertEqual(entry.text, "Read 12 lines")
        XCTAssertEqual(entry.boldRanges, [NSRange(location: 5, length: 2)])
        let one = result(resultLine(id: "1", structured: #"{"file":{"numLines":1}}"#))
        XCTAssertEqual(one.text, "Read 1 line")
    }

    func testResultEditCountsAdditionsAndRemovals() {
        let patch = #"{"filePath":"/w/proj/src/a.swift","structuredPatch":[{"oldStart":1,"lines":[" ctx","-old1","-old2","+new1","+new2","+new3"]},{"oldStart":9,"lines":["+more"," c"]}]}"#
        let entry = result(resultLine(id: "1", content: "The file has been updated", structured: patch))
        XCTAssertEqual(entry.text, "Updated src/a.swift with 4 additions and 2 removals")
        let ns = entry.text as NSString
        XCTAssertEqual(entry.boldRanges.map { ns.substring(with: $0) }, ["4", "2"])
        let single = #"{"filePath":"/w/proj/a","structuredPatch":[{"lines":["-x","+y"]}]}"#
        XCTAssertEqual(result(resultLine(id: "1", structured: single)).text, "Updated a with 1 addition and 1 removal")
        XCTAssertEqual(result(resultLine(id: "1", structured: single)).boldRanges.map { ($0.location, $0.length) }.map { "\($0.0),\($0.1)" }, ["15,1", "30,1"])
    }

    func testResultWriteCreate() {
        let created = #"{"type":"create","filePath":"/w/proj/new.txt","content":"a\nb\nc\n","structuredPatch":[]}"#
        let entry = result(resultLine(id: "1", content: "File created", structured: created))
        XCTAssertEqual(entry.text, "Wrote 3 lines to new.txt")
        XCTAssertEqual((entry.text as NSString).substring(with: entry.boldRanges[0]), "3")
    }

    func testResultGrepGlob() {
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"mode":"files_with_matches","numFiles":5,"filenames":["a"]}"#)).text, "Found 5 files")
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"numFiles":1,"filenames":["a"],"durationMs":3}"#)).text, "Found 1 file")
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"mode":"content","numFiles":2,"numLines":40}"#)).text, "Found 40 lines")
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"numFiles":0,"filenames":[]}"#)).text, "No files found")
    }

    func testResultBashFoldsToThreeLines() {
        let out = (1...7).map { "line\($0)" }.joined(separator: "\n")
        let entry = result(resultLine(id: "1", content: out, structured: #"{"stdout":"\#(out.replacingOccurrences(of: "\n", with: "\\n"))","stderr":"","interrupted":false}"#))
        XCTAssertEqual(entry.text, "line1\nline2\nline3\n… +4 lines")
        // stdout 이 비면 stderr
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"stdout":"","stderr":"boom","interrupted":false}"#)).text, "boom")
        // 둘 다 비면 (No content) — 그려지는 결과다
        let empty = result(resultLine(id: "1", structured: #"{"stdout":"","stderr":"","interrupted":false}"#))
        XCTAssertEqual(empty.text, "(No content)")
        XCTAssertTrue(empty.isVisible)
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"stdout":"partial","stderr":"","interrupted":true}"#)).text, "Interrupted by user")
        // 줄이 길면 300자에서 자른다
        let long = result(resultLine(id: "1", structured: #"{"stdout":"\#(String(repeating: "x", count: 500))","stderr":""}"#))
        XCTAssertEqual(long.text.count, AgentTranscript.resultLimit)
        XCTAssertTrue(long.text.hasSuffix("…"))
        // 정확히 3줄이면 접지 않는다
        XCTAssertEqual(AgentTranscript.foldedLines("a\nb\nc\n\n"), "a\nb\nc")
        XCTAssertEqual(AgentTranscript.foldedLines("a\nb\nc\nd"), "a\nb\nc\n… +1 lines")
    }

    func testResultWebFetchAndFallback() {
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"bytes":16381,"code":200,"codeText":"OK","result":"..."}"#)).text, "Received 16.0KB (200 OK)")
        XCTAssertEqual(result(resultLine(id: "1", structured: #"{"bytes":512,"code":404,"codeText":"Not Found"}"#)).text, "Received 512B (404 Not Found)")
        // 구조를 모르면 tool_result 글
        XCTAssertEqual(result(resultLine(id: "1", content: "plain", structured: #"{"success":true}"#)).text, "plain")
        XCTAssertEqual(result(resultLine(id: "1", content: "no structure")).text, "no structure")
    }

    func testResultErrorKeepsTextAndFlag() {
        let entry = result(resultLine(id: "1", content: "<tool_use_error>File does not exist.</tool_use_error>", structured: nil, isError: true))
        XCTAssertTrue(entry.isError)
        XCTAssertEqual(entry.text, "File does not exist.")
        let multi = result(resultLine(id: "1", content: "Error: a\nb\nc\nd\ne", isError: true))
        XCTAssertEqual(multi.text, "Error: a\nb\nc\n… +2 lines")
        // 구조가 있어도 실패면 글 그대로
        XCTAssertEqual(result(resultLine(id: "1", content: "Exit code 1", structured: #"{"stdout":"","stderr":""}"#, isError: true)).text, "Exit code 1")
    }

    func testParallelResultsIgnoreStructure() {
        // 한 줄에 결과가 둘이면 맨 위 toolUseResult 가 누구 것인지 알 수 없으므로 글만 쓴다
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"A"},{"type":"tool_result","tool_use_id":"b","content":"B"}]},"toolUseResult":{"numFiles":3}}"#
        XCTAssertEqual(AgentTranscript.entries(fromLine: Data(line.utf8)).map(\.text), ["A", "B"])
    }

    func testThinkingEntryEvenWhenEmpty() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"thinking","thinking":"hmm","signature":"d"}]}}"#
        let entries = AgentTranscript.entries(fromLine: Data(line.utf8))
        XCTAssertEqual(entries.map(\.kind), [.thinking, .thinking])
        XCTAssertTrue(entries.allSatisfy { $0.isVisible })
    }

    // MARK: - 마크다운

    private func md(_ source: String) -> [MarkdownRun] { AgentTranscriptMarkdown.parse(source) }

    func testMarkdownInlineStyles() {
        XCTAssertEqual(md("a **b** c"), [MarkdownRun("a "), MarkdownRun("b", bold: true), MarkdownRun(" c")])
        XCTAssertEqual(md("a *b* c"), [MarkdownRun("a "), MarkdownRun("b", italic: true), MarkdownRun(" c")])
        XCTAssertEqual(md("a _b_ c"), [MarkdownRun("a "), MarkdownRun("b", italic: true), MarkdownRun(" c")])
        XCTAssertEqual(md("run `ls -a` now"), [MarkdownRun("run "), MarkdownRun("ls -a", code: true), MarkdownRun(" now")])
        XCTAssertEqual(md("***both***"), [MarkdownRun("both", bold: true, italic: true)])
        XCTAssertEqual(md("**bold `code`**"), [MarkdownRun("bold ", bold: true), MarkdownRun("code", bold: true, code: true)])
        XCTAssertEqual(md("**한글 굵게**"), [MarkdownRun("한글 굵게", bold: true)])
    }

    func testMarkdownUnpairedMarkersStayLiteral() {
        XCTAssertEqual(md("2 * 3 * 4"), [MarkdownRun("2 * 3 * 4")])
        XCTAssertEqual(md("a * b"), [MarkdownRun("a * b")])
        XCTAssertEqual(md("**open only"), [MarkdownRun("**open only")])
        XCTAssertEqual(md("*open only"), [MarkdownRun("*open only")])
        XCTAssertEqual(md("one ` tick"), [MarkdownRun("one ` tick")])
        XCTAssertEqual(md("snake_case_name and __init__"), [MarkdownRun("snake_case_name and __init__")])
        XCTAssertEqual(md("- item * two"), [MarkdownRun("- item * two")])
        XCTAssertEqual(md("* bullet\n* bullet"), [MarkdownRun("* bullet\n* bullet")])
        // 줄을 넘어 짝짓지 않는다
        XCTAssertEqual(md("*a\nb*"), [MarkdownRun("*a\nb*")])
    }

    func testMarkdownHeadings() {
        XCTAssertEqual(md("# Title\nbody"), [MarkdownRun("Title", bold: true, heading: true), MarkdownRun("\nbody")])
        XCTAssertEqual(md("### Sub *x*"), [MarkdownRun("Sub ", bold: true, heading: true), MarkdownRun("x", bold: true, italic: true, heading: true)])
        XCTAssertEqual(md("#nospace"), [MarkdownRun("#nospace")])
        XCTAssertEqual(md("####### seven"), [MarkdownRun("####### seven")])
    }

    func testMarkdownCodeBlockKeepsInsideLiteral() {
        let source = "before **x**\n```swift\nlet a = **b** * 2\n# not heading\n```\nafter"
        XCTAssertEqual(md(source), [
            MarkdownRun("before "), MarkdownRun("x", bold: true),
            MarkdownRun("\nlet a = **b** * 2\n# not heading\nafter"),
        ])
        // 닫는 울타리가 없으면 끝까지 코드 블록, 끝이 울타리면 끝 줄바꿈은 남지 않는다
        XCTAssertEqual(md("a\n```\n*x*"), [MarkdownRun("a\n*x*")])
        XCTAssertEqual(md("a\n```\ncode\n```"), [MarkdownRun("a\ncode")])
        XCTAssertEqual(md(""), [])
    }

    func testMarkdownFenceTwiceOnOneLineIsInlineCode() {
        // 한 줄에 ``` 가 두 번이면 울타리가 아니라 인라인 코드: 뒤의 글이 코드 블록으로 삼켜지지 않는다
        XCTAssertEqual(md("a ```x``` b **c**"), [
            MarkdownRun("a "), MarkdownRun("x", code: true), MarkdownRun(" b "), MarkdownRun("c", bold: true),
        ])
        XCTAssertEqual(md("```x```\n*y*"), [MarkdownRun("x", code: true), MarkdownRun("\n"), MarkdownRun("y", italic: true)])
        // 한 번만 있으면(언어 이름이 붙어도) 여전히 울타리
        XCTAssertEqual(md("```swift\n*x*\n```\n*y*"), [MarkdownRun("*x*\n"), MarkdownRun("y", italic: true)])
        // 인라인 코드의 짝은 같은 길이끼리
        XCTAssertEqual(md("``a`b``"), [MarkdownRun("a`b", code: true)])
    }
}

final class ClaudeTerminalThemeTests: XCTestCase {
    func testNamedPalettes() {
        let dark = ClaudeTerminalTheme.palette(named: "dark", appDark: true)
        XCTAssertEqual(dark.text, .rgb(255, 255, 255))
        XCTAssertEqual(dark.success, .rgb(78, 186, 101))
        XCTAssertEqual(dark.userMessageBackground, .rgb(55, 55, 55))
        let light = ClaudeTerminalTheme.palette(named: "light", appDark: true)
        XCTAssertEqual(light.text, .rgb(0, 0, 0))
        XCTAssertEqual(light.error, .rgb(171, 43, 63))
        XCTAssertEqual(light.permission, .rgb(87, 105, 247))
        let darkDal = ClaudeTerminalTheme.palette(named: "dark-daltonized", appDark: false)
        XCTAssertEqual(darkDal.success, .rgb(51, 153, 255))
        XCTAssertEqual(darkDal.error, .rgb(255, 102, 102))
        XCTAssertEqual(darkDal.permission, .rgb(153, 204, 255))
        XCTAssertEqual(darkDal.inactive, .rgb(153, 153, 153))
        let lightDal = ClaudeTerminalTheme.palette(named: "light-daltonized", appDark: true)
        XCTAssertEqual(lightDal.success, .rgb(0, 102, 153))
        XCTAssertEqual(lightDal.userMessageBackground, .rgb(220, 220, 220))
    }

    func testUnknownOrMissingNameFallsBackToDark() {
        let dark = ClaudeTerminalTheme.palette(named: "dark", appDark: true)
        XCTAssertEqual(ClaudeTerminalTheme.palette(named: "solarized", appDark: false), dark)
        XCTAssertEqual(ClaudeTerminalTheme.palette(named: nil, appDark: false), dark)
        XCTAssertEqual(ClaudeTerminalTheme.palette(named: "", appDark: false), dark)
    }

    func testAutoFollowsAppAppearance() {
        XCTAssertEqual(ClaudeTerminalTheme.palette(named: "auto", appDark: true), ClaudeTerminalTheme.palette(named: "dark", appDark: true))
        XCTAssertEqual(ClaudeTerminalTheme.palette(named: "auto", appDark: false), ClaudeTerminalTheme.palette(named: "light", appDark: true))
    }

    func testAnsiPalettesMapToSixteenColorIndexes() {
        let dark = ClaudeTerminalTheme.palette(named: "dark-ansi", appDark: true)
        XCTAssertEqual([dark.text, dark.inactive, dark.success, dark.error, dark.permission, dark.userMessageBackground],
                       [.ansi(15), .ansi(7), .ansi(10), .ansi(9), .ansi(12), .ansi(8)])
        let light = ClaudeTerminalTheme.palette(named: "light-ansi", appDark: true)
        XCTAssertEqual([light.text, light.inactive, light.success, light.error, light.permission, light.userMessageBackground],
                       [.ansi(0), .ansi(8), .ansi(2), .ansi(1), .ansi(4), .ansi(7)])
        XCTAssertEqual(ClaudeTerminalTheme.ansiIndex("ansi:whiteBright"), 15)
        XCTAssertEqual(ClaudeTerminalTheme.ansiIndex("ansi:white"), 7)
        XCTAssertEqual(ClaudeTerminalTheme.ansiIndex("ansi:blackBright"), 8)
        XCTAssertEqual(ClaudeTerminalTheme.ansiIndex("ansi:greenBright"), 10)
        XCTAssertEqual(ClaudeTerminalTheme.ansiIndex("ansi:blue"), 4)
        XCTAssertNil(ClaudeTerminalTheme.ansiIndex("ansi:teal"))
    }

    func testThemeNameFromConfig() {
        XCTAssertEqual(ClaudeTerminalTheme.themeName(inConfig: Data(#"{"theme":"dark-daltonized","x":1}"#.utf8)), "dark-daltonized")
        XCTAssertNil(ClaudeTerminalTheme.themeName(inConfig: Data(#"{"x":1}"#.utf8)))
        XCTAssertNil(ClaudeTerminalTheme.themeName(inConfig: Data("not json".utf8)))
        XCTAssertNil(ClaudeTerminalTheme.themeName(inConfig: nil))
    }

    func testSettingReadsFileAndRereadsWhenModified() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        let setting = ClaudeThemeSetting(url: { file })
        XCTAssertEqual(setting.name(), "dark") // 파일 없음
        try Data(#"{"theme":"light-ansi"}"#.utf8).write(to: file)
        XCTAssertEqual(setting.name(), "light-ansi")
        // 수정 시각이 같으면 다시 읽지 않는다(내용만 바뀌고 시각이 같은 경우 옛 값)
        let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path) // 시각 되돌릴 때와 같은 값(정밀도)으로 맞춘다
        let fixed = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        _ = setting.name() // 맞춘 시각으로 한 번 읽어 둔다
        try Data(#"{"theme":"light"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)
        XCTAssertEqual(setting.name(), "light-ansi")
        // 시각이 바뀌면 다시 읽는다
        try FileManager.default.setAttributes([.modificationDate: fixed.addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(setting.name(), "light")
        // 읽을 수 없는 내용 → dark
        try Data("{broken".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixed.addingTimeInterval(10)], ofItemAtPath: file.path)
        XCTAssertEqual(setting.name(), "dark")
        // CLAUDE_CONFIG_DIR 를 따르는 위치(PlanUsageFiles.claudeConfig)
        XCTAssertEqual(PlanUsageFiles.claudeConfig(environment: ["CLAUDE_CONFIG_DIR": dir.path]).path, file.path)
    }
}
