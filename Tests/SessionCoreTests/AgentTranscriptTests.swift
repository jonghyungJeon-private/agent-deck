import Foundation
import SessionCore
import XCTest

final class AgentTranscriptTests: XCTestCase {
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
        XCTAssertEqual(entries.map(\.kind), [.text, .tool, .result, .result])
        XCTAssertEqual(entries[0].text.count, AgentTranscript.textLimit)
        XCTAssertTrue(entries[0].text.hasSuffix("…"))
        XCTAssertEqual(entries[1].toolName, "Bash")
        XCTAssertEqual(entries[1].text, "ls -la")
        XCTAssertEqual(entries[2].text, "a b c")
        XCTAssertTrue(entries[2].isError)
        XCTAssertEqual(entries[3].text, "ok")
        XCTAssertFalse(entries[3].isError)
    }

    func testToolSummaryPicksFirstPresentKey() {
        XCTAssertEqual(AgentTranscript.toolSummary(["command": "ls", "description": "list files"]), "list files")
        XCTAssertEqual(AgentTranscript.toolSummary(["description": "  ", "command": "\n\nrun it\nnext"]), "run it")
        XCTAssertEqual(AgentTranscript.toolSummary(["file_path": "/a/b.swift", "pattern": "x"]), "/a/b.swift")
        XCTAssertEqual(AgentTranscript.toolSummary(["pattern": "foo.*"]), "foo.*")
        XCTAssertEqual(AgentTranscript.toolSummary(["url": "https://x.y"]), "https://x.y")
        XCTAssertEqual(AgentTranscript.toolSummary(["prompt": "do it"]), "do it")
        XCTAssertEqual(AgentTranscript.toolSummary(["code": "let a = 1\nlet b"]), "let a = 1")
        XCTAssertEqual(AgentTranscript.toolSummary(["b": 2, "a": "x"]), #"{"a":"x","b":2}"#)
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
        XCTAssertEqual(entries.map(\.text), ["", "ok"])
        XCTAssertEqual(entries.map(\.isError), [true, false])
    }
}
