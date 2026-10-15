import Foundation
@testable import SessionCore
import XCTest

final class SessionNamingTests: XCTestCase {
    func testAutomaticNames() {
        XCTAssertTrue(SessionNaming.isAutomatic("demo_Project-1238", cwd: "/Users/a/demo_Project"))
        XCTAssertTrue(SessionNaming.isAutomatic("shop-api@feature/ABC-123", cwd: "/x/shop-api"))
        XCTAssertTrue(SessionNaming.isAutomatic("app", cwd: "/x/app"))
        XCTAssertFalse(SessionNaming.isAutomatic("결제 버그 수정", cwd: "/x/app"))
        XCTAssertFalse(SessionNaming.isAutomatic("app-login-fix", cwd: "/x/app"))
        XCTAssertFalse(SessionNaming.isAutomatic("app@ 회의 메모", cwd: "/x/app"))
    }

    func testPreview() {
        XCTAssertEqual(SessionNaming.preview(of: "  로그인   버그\n둘째 줄"), "로그인 버그")
        XCTAssertEqual(SessionNaming.preview(of: String(repeating: "가", count: 40), limit: 10), String(repeating: "가", count: 9) + "…")
    }

    func testFirstPromptSkipsMetaAndCommands() throws {
        let lines: [[String: Any]] = [
            ["type": "custom-title", "customTitle": "app-1200"],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: meta"]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "x"]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "image"], ["type": "text", "text": "이 화면 버그 고쳐줘"]]]],
            ["type": "user", "message": ["role": "user", "content": "두 번째 질문"]],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptReader.firstPrompt(path: url.path), "이 화면 버그 고쳐줘")
    }
}
