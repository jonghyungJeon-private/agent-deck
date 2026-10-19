import Foundation
import TermLayout
import XCTest

final class LaunchOptionsTests: XCTestCase {
    func testDefaultsLaunchPlainCommands() {
        let options = LaunchOptions()
        XCTAssertEqual(options.claude.arguments, [])
        XCTAssertEqual(options.claude.command, "claude")
        XCTAssertEqual(options.codex.command, "codex")
    }

    func testClaudeArgumentsOrderAndQuoting() {
        var claude = ClaudeLaunch(permissionMode: "acceptEdits", model: " opus ", extraArgs: "--effort high --append-system-prompt 'be brief, ok'")
        XCTAssertEqual(claude.arguments, ["--permission-mode", "acceptEdits", "--model", "opus",
                                          "--effort", "high", "--append-system-prompt", "be brief, ok"])
        XCTAssertEqual(claude.command, "claude --permission-mode acceptEdits --model opus --effort high --append-system-prompt 'be brief, ok'")
        // 권한 확인 건너뛰기가 켜지면 권한 모드는 쓰지 않는다(둘이 겹치면 뜻이 흐려진다)
        claude.skipPermissions = true
        XCTAssertEqual(Array(claude.arguments.prefix(3)), ["--dangerously-skip-permissions", "--model", "opus"])
        XCTAssertFalse(claude.arguments.contains("--permission-mode"))
        // 빈 모델·빈 모드는 넣지 않는다
        XCTAssertEqual(ClaudeLaunch(permissionMode: "", model: "  ").arguments, [])
    }

    func testCodexArgumentsAndBypassHidesApprovalAndSandbox() {
        var codex = CodexLaunch(approval: "on-request", sandbox: "workspace-write", model: "gpt-5", extraArgs: "--search")
        XCTAssertEqual(codex.command, "codex --ask-for-approval on-request --sandbox workspace-write --model gpt-5 --search")
        codex.bypassApprovalsAndSandbox = true
        XCTAssertEqual(codex.arguments, ["--dangerously-bypass-approvals-and-sandbox", "--model", "gpt-5", "--search"])
    }

    /// 새로 띄운 인자가 되살리기(PaneRecipe.keptArgs·CodexArguments.keptArgs)에도 그대로 남는다
    func testBuiltClaudeArgumentsSurviveRecipeWhitelist() {
        let claude = ClaudeLaunch(skipPermissions: true, model: "sonnet")
        XCTAssertEqual(PaneRecipe.keptArgs(["claude"] + claude.arguments), claude.arguments)
        let mode = ClaudeLaunch(permissionMode: "plan", model: "claude-opus-4-1")
        XCTAssertEqual(PaneRecipe.keptArgs(["/usr/local/bin/claude"] + mode.arguments), mode.arguments)
        XCTAssertEqual(PaneRecipe(cwd: "/tmp", sessionId: "s1", claudeArgs: PaneRecipe.keptArgs(["claude"] + mode.arguments)).resumeCommand,
                       "claude --resume s1 --permission-mode plan --model claude-opus-4-1")
    }

    func testShellWordsSplit() {
        XCTAssertEqual(ShellWords.split("  a  b\tc ").words, ["a", "b", "c"])
        XCTAssertEqual(ShellWords.split("--x 'a b' \"c d\" e\\ f").words, ["--x", "a b", "c d", "e f"])
        XCTAssertEqual(ShellWords.split(#"--p "say \"hi\" \n" ''"#).words, ["--p", #"say "hi" \n"#, ""])
        XCTAssertEqual(ShellWords.split("--k=\"v w\"x").words, ["--k=v wx"])
        XCTAssertEqual(ShellWords.split("").words, [])
        XCTAssertFalse(ShellWords.split("'ok'").unterminated)
        let open = ShellWords.split("--a 'b c")
        XCTAssertTrue(open.unterminated)
        XCTAssertEqual(open.words, ["--a", "b c"])
    }

    func testShellQuoteRoundTrip() {
        let words = ["--append-system-prompt", "it's \"fine\" $HOME", "plain", ""]
        XCTAssertEqual(ShellWords.split(ShellWords.command(words)).words, words)
    }

    func testCodecIsBackwardCompatible() throws {
        // 빈 파일·일부만 있는 파일·모르는 칸·잘못된 형식 → 나머지는 기본값
        XCTAssertEqual(try JSONDecoder().decode(LaunchOptions.self, from: Data("{}".utf8)), LaunchOptions())
        let partial = try JSONDecoder().decode(LaunchOptions.self, from: Data(#"{"claude":{"model":"opus","future":1},"codex":{"approval":7}}"#.utf8))
        XCTAssertEqual(partial.claude, ClaudeLaunch(model: "opus"))
        XCTAssertEqual(partial.codex, CodexLaunch())

        let options = LaunchOptions(claude: ClaudeLaunch(skipPermissions: true, permissionMode: "plan", model: "opus", extraArgs: "--verbose"),
                                    codex: CodexLaunch(bypassApprovalsAndSandbox: true, approval: "never", sandbox: "read-only", model: "m", extraArgs: "-c a=1"))
        let data = try XCTUnwrap(options.data())
        XCTAssertEqual(try JSONDecoder().decode(LaunchOptions.self, from: data), options)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("launch.json")
        XCTAssertEqual(LaunchOptions.load(from: url), LaunchOptions()) // 없음
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(LaunchOptions.load(from: url), LaunchOptions()) // 망가짐
        try data.write(to: url)
        XCTAssertEqual(LaunchOptions.load(from: url), options)
    }

    func testDangerDetection() {
        XCTAssertNotNil(LaunchDanger.claude(["--dangerously-skip-permissions"]))
        XCTAssertNotNil(LaunchDanger.claude(["--permission-mode", "bypassPermissions"]))
        XCTAssertNotNil(LaunchDanger.claude(["--permission-mode=bypassPermissions"]))
        XCTAssertNil(LaunchDanger.claude(["--permission-mode", "plan", "--allow-dangerously-skip-permissions"]))
        XCTAssertNotNil(LaunchDanger.codex(["--yolo"]))
        XCTAssertNotNil(LaunchDanger.codex(["--dangerously-bypass-approvals-and-sandbox"]))
        XCTAssertNotNil(LaunchDanger.codex(["-s", "danger-full-access"]))
        XCTAssertNotNil(LaunchDanger.codex(["--sandbox=danger-full-access"]))
        XCTAssertNil(LaunchDanger.codex(["--sandbox", "workspace-write", "--ask-for-approval", "never"]))
        XCTAssertNil(LaunchDanger.codex([]))
    }
}
