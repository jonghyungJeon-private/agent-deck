import EditorCore
import Foundation
import XCTest

final class LineDiffTests: XCTestCase {
    private func diff(_ base: String, _ current: String) -> [LineChange] {
        LineDiff.changes(base: base, current: current)
    }

    func testLinesSplitting() {
        XCTAssertEqual(LineDiff.lines("").count, 0)
        XCTAssertEqual(LineDiff.lines("a\nb\n").map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        XCTAssertEqual(LineDiff.lines("a\nb").map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        XCTAssertEqual(LineDiff.lines("a\r\nb\r\n").map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        XCTAssertEqual(LineDiff.lines("\n\n").count, 2)
    }

    func testIdenticalHasNoMarkers() {
        XCTAssertEqual(diff("a\nb\nc\n", "a\nb\nc\n"), [])
        XCTAssertEqual(diff("", ""), [])
    }

    func testAddedModifiedDeletedInMiddle() {
        XCTAssertEqual(diff("a\nb\nc\n", "a\nb\nx\ny\nc\n"), [LineChange(.added, start: 2, count: 2)])
        XCTAssertEqual(diff("a\nb\nc\n", "a\nB\nc\n"), [LineChange(.modified, start: 1, count: 1)])
        XCTAssertEqual(diff("a\nb\nc\n", "a\nc\n"), [LineChange(.deleted, start: 1, count: 0)])
    }

    func testChangesAtFileStartAndEnd() {
        XCTAssertEqual(diff("a\nb\n", "new\na\nb\n"), [LineChange(.added, start: 0, count: 1)])
        XCTAssertEqual(diff("a\nb\n", "b\n"), [LineChange(.deleted, start: 0, count: 0)])
        XCTAssertEqual(diff("a\nb\n", "a\nb\nc\n"), [LineChange(.added, start: 2, count: 1)])
        // 끝 줄을 지우면 표시는 줄 수(= 마지막 줄 아래)
        XCTAssertEqual(diff("a\nb\nc\n", "a\nb\n"), [LineChange(.deleted, start: 2, count: 0)])
        XCTAssertEqual(diff("a\nb\n", "A\nb\n"), [LineChange(.modified, start: 0, count: 1)])
        XCTAssertEqual(diff("a\nb\n", "a\nB\n"), [LineChange(.modified, start: 1, count: 1)])
    }

    func testEmptyFiles() {
        XCTAssertEqual(diff("", "a\nb\n"), [LineChange(.added, start: 0, count: 2)])
        XCTAssertEqual(diff("a\nb\n", ""), [LineChange(.deleted, start: 0, count: 0)])
        XCTAssertEqual(LineDiff.allAdded(lineCount: 0), [])
        XCTAssertEqual(LineDiff.allAdded(lineCount: 3), [LineChange(.added, start: 0, count: 3)])
    }

    func testTrailingNewlineOnlyIsNotAChange() {
        XCTAssertEqual(diff("a\nb", "a\nb\n"), [])
        XCTAssertEqual(diff("a\nb\n", "a\nb"), [])
        // 줄 끝 모양(CRLF ↔ LF)만 다른 것도 내용은 같다
        XCTAssertEqual(diff("a\r\nb\r\n", "a\nb\n"), [])
    }

    func testSeveralHunks() {
        let base = (1...10).map { "l\($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...10).map { "l\($0)" }
        lines[1] = "changed"          // 2번째 줄 바뀜
        lines.remove(at: 5)           // l6 지움
        lines.insert("extra", at: 8)  // 새 줄
        let current = lines.joined(separator: "\n") + "\n"
        XCTAssertEqual(diff(base, current), [
            LineChange(.modified, start: 1, count: 1),
            LineChange(.deleted, start: 5, count: 0),
            LineChange(.added, start: 8, count: 1),
        ])
    }

    func testModifiedBlockWithMoreLines() {
        // 두 줄을 세 줄로 바꿈 → 바뀐 덩어리 하나(새 줄 세 개)
        XCTAssertEqual(diff("a\nb\nc\nd\n", "a\nx\ny\nz\nd\n"), [LineChange(.modified, start: 1, count: 3)])
    }

    func testCapFallsBackToOneModifiedBlock() {
        let old: [Int32] = Array(0..<100)
        let new: [Int32] = Array(1000..<1100)
        XCTAssertEqual(LineDiff.changes(old: old, new: new, maxEdits: 10), [LineChange(.modified, start: 0, count: 100)])
        // 상한이 넉넉하면 같은 결과를 Myers 로
        XCTAssertEqual(LineDiff.changes(old: old, new: new, maxEdits: 1000), [LineChange(.modified, start: 0, count: 100)])
    }

    func testRandomEditsMatchLineCounts() {
        // 무작위 편집에서도 덩어리가 겹치지 않고 새 줄 범위 안에 있는지
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let old = (0..<40).map { _ in Int32.random(in: 0..<6, using: &generator) }
            var new = old
            for _ in 0..<5 {
                switch Int.random(in: 0..<3, using: &generator) {
                case 0 where !new.isEmpty: new.remove(at: Int.random(in: 0..<new.count, using: &generator))
                case 1: new.insert(99, at: Int.random(in: 0...new.count, using: &generator))
                default: if !new.isEmpty { new[Int.random(in: 0..<new.count, using: &generator)] = 77 }
                }
            }
            let changes = LineDiff.changes(old: old, new: new)
            var last = -1
            for change in changes {
                XCTAssertGreaterThanOrEqual(change.start, last)
                XCTAssertLessThanOrEqual(change.start + change.count, new.count)
                last = change.start + change.count
            }
            if old == new { XCTAssertEqual(changes, []) }
        }
    }
}

final class TextFileTests: XCTestCase {
    func testLineEndingDetection() {
        XCTAssertEqual(LineEnding.detect("a\nb\n"), .lf)
        XCTAssertEqual(LineEnding.detect("a\r\nb\r\n"), .crlf)
        XCTAssertEqual(LineEnding.detect("a\rb\r"), .cr)
        XCTAssertEqual(LineEnding.detect("a\r\nb\n"), .mixed)
        XCTAssertEqual(LineEnding.detect("no newline"), .lf)
    }

    func testRoundTripKeepsLineEndings() {
        for original in ["a\r\nb\r\n", "a\nb\n", "a\rb", "a\r\nb\nc", "한글\r\n끝"] {
            let decoded = TextFile.decode(Data(original.utf8))!
            XCTAssertFalse(decoded.lineEnding != .mixed && decoded.text.contains("\r"), original)
            XCTAssertEqual(TextFile.encode(decoded.text, lineEnding: decoded.lineEnding, hasBOM: decoded.hasBOM),
                           Data(original.utf8), original)
        }
    }

    func testEditedCRLFTextSavesWithCRLF() {
        let decoded = TextFile.decode(Data("a\r\nb\r\n".utf8))!
        XCTAssertEqual(decoded.text, "a\nb\n")
        let edited = decoded.text + "c\n"
        XCTAssertEqual(TextFile.encode(edited, lineEnding: .crlf, hasBOM: false), Data("a\r\nb\r\nc\r\n".utf8))
        // 붙여넣은 \r\n 이 \r\r\n 이 되지 않게
        XCTAssertEqual(TextFile.encode("x\r\ny\n", lineEnding: .crlf, hasBOM: false), Data("x\r\ny\r\n".utf8))
    }

    func testBOMIsKept() {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8))
        let decoded = TextFile.decode(data)!
        XCTAssertTrue(decoded.hasBOM)
        XCTAssertEqual(decoded.text, "hi\n")
        XCTAssertEqual(TextFile.encode(decoded.text, lineEnding: decoded.lineEnding, hasBOM: true), data)
    }

    func testBinaryAndSizeDetection() {
        XCTAssertEqual(TextFile.classify(size: 10, head: Data("hello".utf8)), .text)
        XCTAssertEqual(TextFile.classify(size: 10, head: Data([0x89, 0x50, 0x00, 0x47])), .binary)
        // NUL 이 8KB 뒤에 있으면 앞부분만 보고 텍스트로
        var late = Data(repeating: 65, count: TextFile.probeBytes)
        late.append(0)
        XCTAssertEqual(TextFile.classify(size: late.count, head: late), .text)
        XCTAssertEqual(TextFile.classify(size: TextFile.maxEditableBytes + 1, head: Data()), .tooLarge(TextFile.maxEditableBytes + 1))
        XCTAssertEqual(TextFile.classify(size: 2, head: Data([0xC3, 0x28]), full: Data([0xC3, 0x28])), .notUTF8)
    }

    func testAtomicWriteKeepsPermissionsAndFollowsSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("editorcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("run.sh").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0o755)
        let link = dir.appendingPathComponent("link.sh").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)

        try TextFile.writeAtomically(Data("new\r\n".utf8), to: link)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), Data("new\r\n".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        // 링크는 링크 그대로
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), file)
        // 임시 파일이 남지 않음
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["link.sh", "run.sh"])
    }

    func testReadClassifiesFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("editorcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("a.txt").path
        let binary = dir.appendingPathComponent("b.bin").path
        try Data("x\r\ny".utf8).write(to: URL(fileURLWithPath: text))
        try Data([1, 2, 0, 3]).write(to: URL(fileURLWithPath: binary))
        let read = try TextFile.read(path: text)
        XCTAssertEqual(read.kind, .text)
        XCTAssertEqual(read.decoded?.lineEnding, .crlf)
        XCTAssertEqual(try TextFile.read(path: binary).kind, .binary)
        XCTAssertNotNil(FileFingerprint.of(text))
        XCTAssertNil(FileFingerprint.of(dir.appendingPathComponent("none").path))
    }
}

final class LineIndexTests: XCTestCase {
    func testBuildAndLookup() {
        let index = LineIndex("ab\ncd\n\nef" as NSString)
        XCTAssertEqual(index.starts, [0, 3, 6, 7])
        XCTAssertEqual(index.line(containing: 0), 0)
        XCTAssertEqual(index.line(containing: 2), 0) // \n 은 그 줄 끝
        XCTAssertEqual(index.line(containing: 3), 1)
        XCTAssertEqual(index.line(containing: 9), 3)
        XCTAssertEqual(LineIndex("" as NSString).lineCount, 1)
        XCTAssertEqual(LineIndex("a\n" as NSString).lineCount, 2)
    }

    func testIncrementalEditsMatchRebuild() {
        var generator = SystemRandomNumberGenerator()
        var text = "line1\nline2\n\nline4\nend"
        var index = LineIndex(text as NSString)
        for _ in 0..<300 {
            let ns = text as NSString
            let location = Int.random(in: 0...ns.length, using: &generator)
            let length = Int.random(in: 0...min(4, ns.length - location), using: &generator)
            let pieces = ["", "x", "\n", "ab\ncd", "\n\n", "한"]
            let insert = pieces[Int.random(in: 0..<pieces.count, using: &generator)]
            let next = ns.replacingCharacters(in: NSRange(location: location, length: length), with: insert)
            let delta = (insert as NSString).length - length
            index.edit(next as NSString, range: NSRange(location: location, length: (insert as NSString).length), delta: delta)
            text = next
            XCTAssertEqual(index, LineIndex(text as NSString), "after editing at \(location)")
        }
    }
}

final class SyntaxTests: XCTestCase {
    private func kinds(_ language: SyntaxLanguage, _ text: String) -> [(SyntaxKind, String)] {
        let ns = text as NSString
        return SyntaxScanner(language).tokens(text).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func assertTokens(_ language: SyntaxLanguage, _ text: String, _ expected: [(SyntaxKind, String)],
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = kinds(language, text)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), "\(actual)", file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
    }

    func testStringWithEscapedQuote() {
        assertTokens(.swift, #"let s = "a\"b" // done"#, [
            (.keyword, "let"), (.string, #""a\"b""#), (.comment, "// done"),
        ])
        assertTokens(.javascript, #"x = 'it\'s' + "q""#, [(.string, #"'it\'s'"#), (.string, #""q""#)])
    }

    func testLineAndBlockComments() {
        assertTokens(.java, "int a = 1; /* note\n still */ return a; // end", [
            (.keyword, "int"), (.number, "1"), (.comment, "/* note\n still */"), (.keyword, "return"), (.comment, "// end"),
        ])
        assertTokens(.python, "x = 3  # count\ny = 'a#b'", [(.number, "3"), (.comment, "# count"), (.string, "'a#b'")])
        // 문자열 안의 주석 기호는 주석이 아니다
        assertTokens(.typescript, #"const g = "src/**/*.ts"; let n = 2"#, [
            (.keyword, "const"), (.string, #""src/**/*.ts""#), (.keyword, "let"), (.number, "2"),
        ])
    }

    func testBlockCommentStateCarriesOver() {
        let scanner = SyntaxScanner(.go)
        XCTAssertEqual(scanner.endState("x := 1 /* open"), .blockComment(depth: 1))
        XCTAssertEqual(scanner.endState("still */ y"), .normal)
        let continued = scanner.tokens("still */ return", state: .blockComment(depth: 1))
        XCTAssertEqual(continued.first, SyntaxToken(.comment, 0, 8))
        XCTAssertEqual(continued.last?.kind, .keyword)
        // Swift 는 겹친 주석
        XCTAssertEqual(SyntaxScanner(.swift).endState("/* a /* b */ c"), .blockComment(depth: 1))
        XCTAssertEqual(SyntaxScanner(.java).endState("/* a /* b */ c"), .normal)
    }

    func testMultilineStrings() {
        let scanner = SyntaxScanner(.python)
        XCTAssertEqual(scanner.endState("s = \"\"\"doc\nmore"), .string(close: "\"\"\"", escapes: true))
        assertTokens(.python, "s = '''a\nb''' + 1", [(.string, "'''a\nb'''"), (.number, "1")])
        assertTokens(.typescript, "const t = `a ${x}\nb`;", [(.keyword, "const"), (.string, "`a ${x}\nb`")])
    }

    func testNumbersTypesAndAttributes() {
        assertTokens(.swift, "@MainActor final class Foo: Bar { var x = 0x1F + 1.5e-3 }", [
            (.attribute, "@MainActor"), (.keyword, "final"), (.keyword, "class"), (.type, "Foo"), (.type, "Bar"),
            (.keyword, "var"), (.number, "0x1F"), (.number, "1.5e-3"),
        ])
        assertTokens(.rust, "fn f<'a>(c: char) { let c = 'x'; }", [
            (.keyword, "fn"), (.attribute, "'a"), (.keyword, "let"), (.string, "'x'"),
        ])
    }

    func testDataFormats() {
        assertTokens(.json, #"{"name": "x", "n": 3, "ok": true}"#, [
            (.key, #""name""#), (.string, #""x""#), (.key, #""n""#), (.number, "3"), (.key, #""ok""#), (.keyword, "true"),
        ])
        assertTokens(.yaml, "name: app # c\n- item: 2\nurl: \"http://x\"", [
            (.key, "name"), (.comment, "# c"), (.key, "item"), (.number, "2"), (.key, "url"), (.string, "\"http://x\""),
        ])
        assertTokens(.toml, "[package]\nname = \"x\"", [(.heading, "[package]"), (.key, "name"), (.string, "\"x\"")])
    }

    func testShellSqlMarkdown() {
        assertTokens(.shell, "echo \"$HOME\" $# # note\nif [ -f x ]; then", [
            (.string, "\"$HOME\""), (.attribute, "$#"), (.comment, "# note"), (.keyword, "if"), (.keyword, "then"),
        ])
        assertTokens(.sql, "SELECT 'it''s' FROM t -- c", [(.keyword, "SELECT"), (.string, "'it''s'"), (.keyword, "FROM"), (.comment, "-- c")])
        assertTokens(.markdown, "# Title\ntext `code` here\n```\nlet x\n```\n- item", [
            (.heading, "# Title"), (.string, "`code`"), (.string, "```"), (.string, "let x"), (.string, "```"), (.keyword, "-"),
        ])
    }

    func testLanguageDetection() {
        XCTAssertEqual(SyntaxLanguage.detect(path: "/a/b/Main.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage.detect(path: "x.tsx"), .typescript)
        XCTAssertEqual(SyntaxLanguage.detect(path: "/x/.zshrc"), .shell)
        XCTAssertEqual(SyntaxLanguage.detect(path: "Cargo.toml"), .toml)
        XCTAssertNil(SyntaxLanguage.detect(path: "notes.txt"))
    }
}
