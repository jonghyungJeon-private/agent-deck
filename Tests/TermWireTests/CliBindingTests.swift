import XCTest
@testable import TermWire

final class CliBindingTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clibind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testShimExecsBundledHelper() throws {
        let helper = dir.appendingPathComponent("Helpers/agentdeck")
        let bin = try XCTUnwrap(CliBinding.installShim(helper: helper, daemon: nil, termDir: dir))
        XCTAssertEqual(bin, BrowserBinding.binDir(termDir: dir), "abx 와 같은 폴더 — PATH 에 한 번만 넣는다")
        let shim = bin.appendingPathComponent("agentdeck")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shim.path))
        let text = try String(contentsOf: shim, encoding: .utf8)
        XCTAssertTrue(text.contains("exec '\(helper.path)' \"$@\""), text)
    }

    func testShimPrefersDaemonCliOverHelperLink() throws {
        // 링크 경로가 풀려 이름이 AgentDeckDaemon 으로 보여도 cli 로 가게(이름에 기대지 않는다)
        let helper = dir.appendingPathComponent("Helpers/agentdeck")
        let daemon = URL(fileURLWithPath: "/x/AgentDeckDaemon")
        let bin = try XCTUnwrap(CliBinding.installShim(helper: helper, daemon: daemon, termDir: dir))
        let text = try String(contentsOf: bin.appendingPathComponent("agentdeck"), encoding: .utf8)
        XCTAssertTrue(text.contains("exec '/x/AgentDeckDaemon' cli \"$@\""), text)
    }

    func testShimFallsBackToDaemonCliAndQuotesPaths() throws {
        let daemon = URL(fileURLWithPath: "/tmp/it's here/AgentDeckDaemon")
        let bin = try XCTUnwrap(CliBinding.installShim(helper: nil, daemon: daemon, termDir: dir))
        let text = try String(contentsOf: bin.appendingPathComponent("agentdeck"), encoding: .utf8)
        XCTAssertTrue(text.contains("exec '/tmp/it'\\''s here/AgentDeckDaemon' cli \"$@\""), text)
    }

    func testNoTargetRemovesShimAndReturnsNil() throws {
        _ = CliBinding.installShim(helper: nil, daemon: URL(fileURLWithPath: "/x/AgentDeckDaemon"), termDir: dir)
        XCTAssertNil(CliBinding.installShim(helper: nil, daemon: nil, termDir: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BrowserBinding.binDir(termDir: dir).appendingPathComponent("agentdeck").path))
    }

    func testBundledHelperIsFoundNextToMacOS() throws {
        let macos = dir.appendingPathComponent("A.app/Contents/MacOS", isDirectory: true)
        let helpers = dir.appendingPathComponent("A.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("AgentDeckDaemon")
        XCTAssertNil(CliBinding.bundledHelper(executable: exe))
        let helper = helpers.appendingPathComponent("agentdeck")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(CliBinding.bundledHelper(executable: exe)?.lastPathComponent, "agentdeck")
        XCTAssertNil(CliBinding.bundledHelper(executable: nil))
    }
}
