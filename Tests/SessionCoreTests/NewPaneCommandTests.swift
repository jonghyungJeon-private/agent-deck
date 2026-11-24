import XCTest
@testable import SessionCore
import TermLayout

/// `agentdeck new --model·--effort`: 설정의 기본 옵션 위에 칸마다의 모델·effort 를 덧씌운다
final class NewPaneCommandTests: XCTestCase {
    func words(_ command: String?) -> [String] { ShellWords.split(command ?? "").words }

    func testClaudeKeepsLaunchDefaultsWithoutOverrides() throws {
        var launch = LaunchOptions()
        launch.claude.permissionMode = "acceptEdits"
        launch.claude.model = "opus"
        let cmd = try NewPaneCommand.command(kind: .claude, launch: launch, model: nil, effort: nil, name: "리뷰어")
        XCTAssertEqual(words(cmd), ["claude", "--permission-mode", "acceptEdits", "--model", "opus", "--name", "리뷰어"])
    }

    func testClaudeModelAndEffortOverrideDefaultsAndExtraArgs() throws {
        var launch = LaunchOptions()
        launch.claude.model = "opus"
        launch.claude.extraArgs = "--effort max --model=fable --verbose"
        let cmd = try NewPaneCommand.command(kind: .claude, launch: launch, model: "sonnet", effort: "HIGH", name: nil)
        let w = words(cmd)
        XCTAssertEqual(w.filter { $0 == "--model" || $0.hasPrefix("--model=") }.count, 1, cmd ?? "")
        XCTAssertEqual(w.filter { $0 == "--effort" }.count, 1, cmd ?? "")
        XCTAssertTrue(w.contains("--verbose"))
        XCTAssertEqual(w.suffix(4), ["--effort", "high", "--model", "sonnet"])
    }

    func testCodexModelAndEffort() throws {
        var launch = LaunchOptions()
        launch.codex.sandbox = "workspace-write"
        launch.codex.extraArgs = "-m o3"
        let cmd = try NewPaneCommand.command(kind: .codex, launch: launch, model: "gpt-5.5", effort: "xhigh", name: "x")
        XCTAssertEqual(words(cmd), ["codex", "--sandbox", "workspace-write", "--model", "gpt-5.5", "-c", "model_reasoning_effort=\"xhigh\""])
    }

    func testCodexWithoutOverridesMatchesLaunchCommand() throws {
        var launch = LaunchOptions()
        launch.codex.approval = "on-request"
        XCTAssertEqual(try NewPaneCommand.command(kind: .codex, launch: launch, model: nil, effort: nil, name: nil), launch.codex.command)
    }

    func testInvalidValuesAreRefused() {
        let launch = LaunchOptions()
        XCTAssertThrowsError(try NewPaneCommand.command(kind: .claude, launch: launch, model: nil, effort: "minimal", name: nil))
        XCTAssertThrowsError(try NewPaneCommand.command(kind: .codex, launch: launch, model: nil, effort: "max", name: nil))
        XCTAssertThrowsError(try NewPaneCommand.command(kind: .claude, launch: launch, model: "--dangerously-skip-permissions", effort: nil, name: nil))
        XCTAssertThrowsError(try NewPaneCommand.command(kind: .claude, launch: launch, model: "a b", effort: nil, name: nil))
        XCTAssertThrowsError(try NewPaneCommand.command(kind: .claude, launch: launch, model: "", effort: nil, name: nil))
        XCTAssertThrowsError(try NewPaneCommand.command(kind: .shell, launch: launch, model: "sonnet", effort: nil, name: nil))
        XCTAssertNil(try NewPaneCommand.command(kind: .shell, launch: launch, model: nil, effort: nil, name: nil))
    }

    func testOverridesRemoveEqualsFormsAndKeepFlagWithoutValue() throws {
        var launch = LaunchOptions()
        launch.claude.skipPermissions = true
        launch.claude.extraArgs = "--effort=max --verbose --model"
        let cmd = try NewPaneCommand.command(kind: .claude, launch: launch, model: "  haiku ", effort: "low", name: nil)
        XCTAssertEqual(words(cmd), ["claude", "--dangerously-skip-permissions", "--verbose", "--effort", "low", "--model", "haiku"])
    }

    func testCodexOverridesConfigFormsInExtraArgs() throws {
        var launch = LaunchOptions()
        launch.codex.bypassApprovalsAndSandbox = true
        launch.codex.extraArgs = "--model=o3 -c model=\"o4\" --config model_reasoning_effort=low -c foo=1"
        let cmd = try NewPaneCommand.command(kind: .codex, launch: launch, model: "gpt-5.5", effort: "high", name: nil)
        XCTAssertEqual(words(cmd), ["codex", "--dangerously-bypass-approvals-and-sandbox", "-c", "foo=1", "--model", "gpt-5.5", "-c", "model_reasoning_effort=\"high\""])
    }

    func testFlagWithoutValueKeepsNextOption() {
        XCTAssertEqual(NewPaneCommand.removing(["--effort"], from: ["--effort", "--verbose", "x"]), ["--verbose", "x"])
        XCTAssertEqual(NewPaneCommand.removing(["--effort"], from: ["a", "--effort"]), ["a"])
    }

    func testModelOverrideKeepsOtherModelPrefixedConfigs() throws {
        var launch = LaunchOptions()
        launch.codex.extraArgs = "-c model=o4 -c model_reasoning_effort=low --config model_provider=x"
        let cmd = try NewPaneCommand.command(kind: .codex, launch: launch, model: "gpt-5.5", effort: nil, name: nil)
        XCTAssertEqual(words(cmd), ["codex", "-c", "model_reasoning_effort=low", "--config", "model_provider=x", "--model", "gpt-5.5"])
    }

    func testModelWithShellCharactersIsQuoted() throws {
        let cmd = try NewPaneCommand.command(kind: .claude, launch: LaunchOptions(), model: "x;rm", effort: nil, name: nil)
        XCTAssertEqual(words(cmd), ["claude", "--model", "x;rm"])
        XCTAssertFalse(cmd?.contains(" x;rm") ?? true, cmd ?? "")
    }
}
