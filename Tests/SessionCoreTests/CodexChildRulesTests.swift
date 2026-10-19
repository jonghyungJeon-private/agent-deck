import Foundation
import SessionCore
import XCTest

final class CodexChildRulesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testLongRunningChildSurvivesOldStateTimestamp() {
        for state in ["working", "inProgress", "in_progress", "running"] {
            XCTAssertEqual(CodexChildRules.activity(state: state, stateAt: now.addingTimeInterval(-2 * 86400),
                edgeStatus: "open", lastActivityAt: now.addingTimeInterval(-300), now: now), .running)
        }
    }

    func testClosedAndFinishedChildrenAgeOutDespiteRecentFileWrites() {
        let old = now.addingTimeInterval(-CodexChildRules.finishedRetention)
        XCTAssertNil(CodexChildRules.activity(state: "working", stateAt: old,
            edgeStatus: "closed", lastActivityAt: now, now: now))
        for state in ["done", "idle", "error"] {
            XCTAssertNil(CodexChildRules.activity(state: state, stateAt: old,
                edgeStatus: "open", lastActivityAt: now, now: now))
            XCTAssertEqual(CodexChildRules.activity(state: state, stateAt: now,
                edgeStatus: "open", lastActivityAt: now, now: now), .stopped)
        }
        XCTAssertEqual(CodexChildRules.activity(state: "working", stateAt: now,
            edgeStatus: "closed", lastActivityAt: now, now: now), .stopped)
    }

    func testAbandonedWorkingChildEventuallyAgesOutByFileInactivity() {
        let old = now.addingTimeInterval(-CodexChildRules.abandonedRetention)
        XCTAssertNil(CodexChildRules.activity(state: "working", stateAt: old,
            edgeStatus: "open", lastActivityAt: old, now: now))
        XCTAssertEqual(CodexChildRules.activity(state: "working", stateAt: old,
            edgeStatus: "open", lastActivityAt: old.addingTimeInterval(1), now: now), .running)
        XCTAssertEqual(CodexChildRules.activity(state: "working", stateAt: now,
            edgeStatus: "open", lastActivityAt: old, now: now), .running)
    }

    func testMissingFileTimestampDoesNotExpireWorkingChildByStateAge() {
        XCTAssertEqual(CodexChildRules.activity(state: "working", stateAt: .distantPast,
            edgeStatus: "open", lastActivityAt: nil, now: now), .running)
        XCTAssertEqual(CodexChildRules.activity(state: "waiting", stateAt: .distantPast,
            edgeStatus: "open", lastActivityAt: now, now: now), .stopped)
    }
}
