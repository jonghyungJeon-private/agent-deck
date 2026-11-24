import XCTest
@testable import SessionCore

final class CliLinkInstallerTests: XCTestCase {
    var dir: URL!
    var target: URL!
    var link: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-link-\(UUID().uuidString)", isDirectory: true)
        let helpers = dir.appendingPathComponent("A.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        target = helpers.appendingPathComponent("agentdeck")
        try Data("#!/bin/sh\n".utf8).write(to: target)
        link = dir.appendingPathComponent("home/.local/bin/agentdeck")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testInstallCreatesDirectoryAndLinkThenRemoves() throws {
        let installer = CliLinkInstaller(link: link, target: target)
        XCTAssertEqual(installer.status(), .notInstalled)
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        try installer.install() // 다시 해도 그대로
        XCTAssertTrue(try installer.uninstall())
        XCTAssertEqual(installer.status(), .notInstalled)
        XCTAssertFalse(try installer.uninstall())
    }

    func testDoesNotOverwriteUserFileOrForeignLink() throws {
        let installer = CliLinkInstaller(link: link, target: target)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: link)
        XCTAssertEqual(installer.status(), .userManaged)
        XCTAssertThrowsError(try installer.install())
        XCTAssertFalse(try installer.uninstall(), "직접 둔 파일은 지우지 않는다")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "mine")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/local/bin/other-agentdeck")
        XCTAssertEqual(installer.status(), .userManaged)
        XCTAssertThrowsError(try installer.install())
    }

    func testReplacesLinkToMovedAppButNotBrokenForeignOne() throws {
        let old = dir.appendingPathComponent("Old.app/Contents/Helpers/agentdeck")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old) // 깨진 링크지만 이 앱 계열
        let installer = CliLinkInstaller(link: link, target: target)
        XCTAssertEqual(installer.status(), .outdated)
        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
    }

    func testSkillMarkerNoteIsConfigurable() throws {
        let skills = dir.appendingPathComponent("skills", isDirectory: true)
        let installer = SkillInstaller(skillsDir: skills, name: "agentdeck-orchestrate", markerNote: "설정 → 연결에서 뺄 수 있습니다.\n")
        try installer.install(content: "# s\n")
        XCTAssertEqual(try String(contentsOf: installer.skillDir.appendingPathComponent(SkillInstaller.marker), encoding: .utf8),
                       "설정 → 연결에서 뺄 수 있습니다.\n")
        XCTAssertEqual(installer.status(content: "# s\n"), .installed)
    }
}
