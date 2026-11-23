import XCTest
@testable import SessionCore

final class UpdateSelfInstallTests: XCTestCase {
    func testSelfUpdateCommandRunsInstallerWithPipefailAndClosesOnSuccess() {
        let command = UpdateCheck.selfUpdateCommand(gh: "/opt/homebrew/bin/gh")
        XCTAssertEqual(command, "/bin/bash -o pipefail -c '/opt/homebrew/bin/gh api repos/\(UpdateCheck.repository)/contents/scripts/install.sh"
            + " -H '\\''Accept: application/vnd.github.raw'\\'' | /bin/bash' && exit")
    }

    func testSelfUpdateCommandQuotesGhPathWithSpaces() {
        let command = UpdateCheck.selfUpdateCommand(gh: "/Users/a b/bin/gh")
        // 안쪽 명령 안에서 한 번, 바깥 -c 인자로 한 번 감싼다
        XCTAssertTrue(command.hasPrefix("/bin/bash -o pipefail -c ''\\''/Users/a b/bin/gh'\\'' api "), command)
        XCTAssertEqual(UpdateCheck.selfUpdateCommand(gh: nil).contains("-c 'gh api "), true)
    }

    func testSelfUpdateCommandRunsInBash() throws {
        // 바깥 따옴표가 셸에서 그대로 풀리는지: gh 대신 echo 로 바꿔 실제 bash 에 넣어 본다(네트워크 없음)
        let command = UpdateCheck.selfUpdateCommand(gh: "/bin/echo").replacingOccurrences(of: "| /bin/bash", with: "| /bin/cat")
            .replacingOccurrences(of: " && exit", with: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(text, "api repos/\(UpdateCheck.repository)/contents/scripts/install.sh -H Accept: application/vnd.github.raw\n")
    }

    func testInstalledLocation() {
        XCTAssertTrue(UpdateCheck.isInstalledLocation(bundlePath: "/Applications/AgentDeck.app", home: "/Users/me"))
        XCTAssertTrue(UpdateCheck.isInstalledLocation(bundlePath: "/Users/me/Applications/AgentDeck.app/", home: "/Users/me"))
        XCTAssertFalse(UpdateCheck.isInstalledLocation(bundlePath: "/Users/me/dev/agent-deck/dist/AgentDeck.app", home: "/Users/me"))
        XCTAssertFalse(UpdateCheck.isInstalledLocation(bundlePath: "/Applications/Tools/AgentDeck.app", home: "/Users/me"))
        // 시험용 앱 폴더가 정해지면 그 폴더만
        XCTAssertTrue(UpdateCheck.isInstalledLocation(bundlePath: "/tmp/apps/AgentDeck.app", home: "/Users/me", appsDir: "/tmp/apps"))
        XCTAssertFalse(UpdateCheck.isInstalledLocation(bundlePath: "/Applications/AgentDeck.app", home: "/Users/me", appsDir: "/tmp/apps"))
    }
}
