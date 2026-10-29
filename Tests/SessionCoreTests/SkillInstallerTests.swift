import XCTest
@testable import SessionCore

final class SkillInstallerTests: XCTestCase {
    var dir: URL!
    let skill = "---\nname: abx\ndescription: browser\n---\n\n# abx\n"
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testInstallUpdateAndRemoveOnlyOurs() throws {
        let installer = SkillInstaller(skillsDir: dir.appendingPathComponent("skills"), name: "abx")
        XCTAssertEqual(installer.status(content: skill), .notInstalled)
        try installer.install(content: skill)
        XCTAssertEqual(installer.status(content: skill), .installed)
        XCTAssertEqual(try String(contentsOf: installer.skillDir.appendingPathComponent("SKILL.md"), encoding: .utf8), skill)
        // 남은 임시 폴더가 없다(다른 스킬로 보이지 않게)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.skillsDir.path), ["abx"])

        let newer = skill + "more\n"
        XCTAssertEqual(installer.status(content: newer), .outdated)
        try installer.install(content: newer)
        XCTAssertEqual(installer.status(content: newer), .installed)

        XCTAssertTrue(try installer.uninstall())
        XCTAssertEqual(installer.status(content: newer), .notInstalled)
        XCTAssertFalse(try installer.uninstall())
    }

    func testLeavesUserManagedSkillsAlone() throws {
        let fm = FileManager.default
        // 개발용 링크(abx scripts/install.sh) — 깨진 링크여도 직접 둔 것이다
        let source = dir.appendingPathComponent("abx-dev/skill")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "dev".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let linked = SkillInstaller(skillsDir: dir.appendingPathComponent("linked"), name: "abx")
        try fm.createDirectory(at: linked.skillsDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.skillDir, withDestinationURL: source)
        XCTAssertEqual(linked.status(content: skill), .userManaged)
        XCTAssertThrowsError(try linked.install(content: skill))
        XCTAssertFalse(try linked.uninstall())
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8), "dev")

        try fm.removeItem(at: source)
        XCTAssertEqual(linked.status(content: skill), .userManaged)
        XCTAssertFalse(try linked.uninstall())

        // 표식 없는 폴더(직접 복사한 스킬)
        let copied = SkillInstaller(skillsDir: dir.appendingPathComponent("copied"), name: "abx")
        try fm.createDirectory(at: copied.skillDir, withIntermediateDirectories: true)
        try "mine".write(to: copied.skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(copied.status(content: skill), .userManaged)
        XCTAssertFalse(try copied.uninstall())
        XCTAssertTrue(fm.fileExists(atPath: copied.skillDir.appendingPathComponent("SKILL.md").path))
    }

    func testUpdateDoesNotWriteThroughALinkThatReplacedOurs() throws {
        let fm = FileManager.default
        let installer = SkillInstaller(skillsDir: dir.appendingPathComponent("skills"), name: "abx")
        try installer.install(content: skill)
        // 우리 폴더가 사용자 링크로 바뀐 뒤(확인 이후의 교체와 같은 상황) 갱신·빼기는 링크 대상을 건드리지 않는다
        try fm.removeItem(at: installer.skillDir)
        let source = dir.appendingPathComponent("dev")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createFile(atPath: source.appendingPathComponent(SkillInstaller.marker).path, contents: nil)
        try "dev".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: installer.skillDir, withDestinationURL: source)
        XCTAssertThrowsError(try installer.install(content: skill + "new"))
        XCTAssertFalse(try installer.uninstall())
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8), "dev")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: installer.skillDir.path), source.path)
    }

    func testTargets() {
        let claude = SkillInstaller.claude(name: "abx", claudeDir: URL(fileURLWithPath: "/c"))
        XCTAssertEqual(claude.skillDir.path, "/c/skills/abx")
        let codex = SkillInstaller.codex(name: "abx", home: URL(fileURLWithPath: "/h"))
        XCTAssertEqual(codex.skillDir.path, "/h/.agents/skills/abx")
    }
}
