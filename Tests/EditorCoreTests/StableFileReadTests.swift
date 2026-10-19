import EditorCore
import Foundation
import XCTest

final class StableFileReadTests: XCTestCase {
    var directory: URL!
    var file: URL { directory.appendingPathComponent("document.txt") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stable-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testReplacementBetweenReadAndStatRetriesWithNewContent() throws {
        var reads = 0
        let snapshot = try StableFileRead.read(fingerprint: { FileFingerprint.of(self.file.path) }) {
            reads += 1
            let data = try Data(contentsOf: file)
            if reads == 1 { try Data("new".utf8).write(to: file, options: .atomic) }
            return data
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(snapshot.value, Data("new".utf8))
        XCTAssertEqual(snapshot.fingerprint, FileFingerprint.of(file.path))
    }

    func testContinuousReplacementRejectsSnapshotAfterThreeReads() throws {
        var reads = 0
        XCTAssertThrowsError(try StableFileRead.read(fingerprint: { FileFingerprint.of(self.file.path) }) {
            let data = try Data(contentsOf: file)
            reads += 1
            try Data("revision \(reads)".utf8).write(to: file, options: .atomic)
            return data
        }) { error in
            guard case StableFileRead.Failure.unstable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reads, 3)
    }

    func testReadFailureDuringReplacementRetries() throws {
        var reads = 0
        let snapshot = try StableFileRead.read(fingerprint: { FileFingerprint.of(self.file.path) }) {
            reads += 1
            if reads == 1 {
                try Data("new".utf8).write(to: file, options: .atomic)
                throw CocoaError(.fileReadUnknown)
            }
            return try Data(contentsOf: file)
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(snapshot.value, Data("new".utf8))
    }

    func testMissingFingerprintCannotValidateContent() {
        XCTAssertThrowsError(try StableFileRead.read(fingerprint: { nil }) { "unverified" }) { error in
            guard case StableFileRead.Failure.unstable = error else { return XCTFail("\(error)") }
        }
    }

    func testStableReadFailureIsPreserved() {
        XCTAssertThrowsError(try StableFileRead.read(fingerprint: { FileFingerprint.of(self.file.path) }) {
            throw CocoaError(.fileReadNoPermission)
        }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
        }
    }

    func testSaveFingerprintStillIdentifiesOwnFileAfterReplacement() throws {
        let saved = try TextFile.writeAtomically(Data("mine".utf8), to: file.path)
        XCTAssertEqual(saved, FileFingerprint.of(file.path))
        try Data("agent".utf8).write(to: file, options: .atomic)
        XCTAssertNotEqual(saved, FileFingerprint.of(file.path))
    }
}
