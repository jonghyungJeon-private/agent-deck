import Foundation
@testable import SessionCore
import XCTest

final class PlanUsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_565_000) // 2026-10-21 06:43:20Z
    var seoul: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    // rollout 은 한 줄 JSON(공백 없음) — 읽는 쪽이 바이트 표시로 거른다
    func tokenLine(_ id: String, primary: Double, secondary: Double, at: String = "2026-10-21T06:40:00.000Z") -> String {
        #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"\#(id)","primary":{"used_percent":\#(primary),"window_minutes":300,"resets_at":1792576346},"secondary":{"used_percent":\#(secondary),"window_minutes":10080,"resets_at":1793082773},"plan_type":"plus"}}}"#
    }

    func testCodexTakesLastCodexLimitAndSkipsOthers() {
        let premium = #"{"timestamp":"2026-10-21T06:41:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#
        let tail = "ed\":1}\n" + tokenLine("codex", primary: 10, secondary: 20) + "\n"
            + tokenLine("codex", primary: 88, secondary: 31) + "\n" + premium + "\n"
            + #"{"timestamp":"x","type":"response_item","payload":{"type":"message"}}"# + "\n"
        let usage = PlanUsageParser.codexRateLimits(tail: Data(tail.utf8), fallbackDate: .distantPast)
        XCTAssertEqual(usage?.fiveHour, UsageWindow(percent: 88, resetsAt: Date(timeIntervalSince1970: 1_792_576_346)))
        XCTAssertEqual(usage?.weekly?.percent, 31)
        XCTAssertEqual(usage?.recordedAt, PlanUsageParser.isoDate("2026-10-21T06:40:00Z"))
        XCTAssertEqual(usage?.source, .codexRollout)
    }

    func testCodexIgnoresTruncatedFirstLineAndMissingData() {
        let line = tokenLine("codex", primary: 50, secondary: 60)
        let cut = String(line.dropFirst(40))
        XCTAssertNil(PlanUsageParser.codexRateLimits(tail: Data(cut.utf8), fallbackDate: now))
        XCTAssertNil(PlanUsageParser.codexRateLimits(tail: Data(), fallbackDate: now))
        // 시각이 없으면 파일 수정 시각을 쓴다
        let noTime = line.replacingOccurrences(of: #""timestamp":"2026-10-21T06:40:00.000Z","#, with: "")
        XCTAssertEqual(PlanUsageParser.codexRateLimits(tail: Data(noTime.utf8), fallbackDate: now)?.recordedAt, now)
    }

    func testCcDashFile() {
        let json = #"{"at":1792565394771,"sid":"s","limits":[{"kind":"five_hour","pct":37,"resetsAt":"2026-10-21T09:40:00.000Z"},{"kind":"seven_day","pct":62,"resetsAt":"2026-10-23T22:00:00.000Z"},{"kind":"spend_limit","pct":5}],"history":[]}"#
        let usage = PlanUsageParser.ccDash(Data(json.utf8))
        XCTAssertEqual(usage?.fiveHour?.percent, 37)
        XCTAssertEqual(usage?.fiveHour?.resetsAt, PlanUsageParser.isoDate("2026-10-21T09:40:00Z"))
        XCTAssertEqual(usage?.weekly?.percent, 62)
        XCTAssertEqual(usage!.recordedAt.timeIntervalSince1970, 1_792_565_394.771, accuracy: 0.001)
        XCTAssertNil(PlanUsageParser.ccDash(Data(#"{"at":1,"limits":[]}"#.utf8)))
        XCTAssertNil(PlanUsageParser.ccDash(Data("not json".utf8)))
    }

    func testClaudeConfigCacheIsCutOutOfLargeFile() {
        let config = """
            {
              "numStartups": 3,
              "note": "a } brace and \\" quote in a string",
              "cachedUsageUtilization": {
                "fetchedAtMs": 1792035946256,
                "utilization": {
                  "five_hour": { "utilization": 100, "resets_at": "2026-10-15T04:10:00.090304+00:00" },
                  "seven_day": { "utilization": 91, "resets_at": "2026-10-16T22:00:00.090327+00:00" },
                  "seven_day_opus": null,
                  "limits": [{ "kind": "session", "scope": { "label": "}{" } }]
                }
              },
              "after": true
            }
            """
        let usage = PlanUsageParser.claudeCache(configFile: Data(config.utf8))
        XCTAssertEqual(usage?.fiveHour?.percent, 100)
        XCTAssertEqual(usage?.weekly?.percent, 91)
        XCTAssertEqual(usage!.fiveHour!.resetsAt!.timeIntervalSince1970,
                       PlanUsageParser.isoDate("2026-10-15T04:10:00Z")!.timeIntervalSince1970 + 0.090304, accuracy: 0.0001)
        XCTAssertEqual(usage?.source, .claudeCache)
        XCTAssertNil(PlanUsageParser.claudeCache(configFile: Data(#"{"cachedUsageUtilization":null}"#.utf8)))
        XCTAssertNil(PlanUsageParser.claudeCache(configFile: Data(#"{"other":1}"#.utf8)))
    }

    func testTiers() {
        XCTAssertEqual(UsageTier(percent: 69.4), .normal)
        XCTAssertEqual(UsageTier(percent: 70), .warn)
        XCTAssertEqual(UsageTier(percent: 89.9), .warn)
        XCTAssertEqual(UsageTier(percent: 90), .critical)
        XCTAssertEqual(UsageCell(label: "5h", percent: nil).tier, .normal)
        XCTAssertEqual(UsageCell(label: "5h", percent: 35.6).text, "36%")
        XCTAssertEqual(UsageCell(label: "5h", percent: nil).text, "—")
    }

    func testLineMarksResetWindowsAndStaleness() {
        let usage = PlanUsage(fiveHour: UsageWindow(percent: 95, resetsAt: now.addingTimeInterval(-60)),
                              weekly: UsageWindow(percent: 61, resetsAt: now.addingTimeInterval(2 * 86400)),
                              recordedAt: now.addingTimeInterval(-120), source: .ccDash)
        let line = UsageSummary.line(provider: "Claude", usage: usage, now: now, calendar: seoul, missingHelp: "")
        XCTAssertEqual(line.cells, [UsageCell(label: "5h", percent: nil), UsageCell(label: "7d", percent: 61)])
        XCTAssertFalse(line.stale)
        XCTAssertTrue(line.help.contains("2분 전 기록 (cc-dash 기록)"), line.help)
        XCTAssertTrue(line.help.contains("주간: 61% 사용 · 10/23 15:43 초기화"), line.help)

        var old = usage
        old.recordedAt = now.addingTimeInterval(-UsageSummary.staleAfter - 1)
        XCTAssertTrue(UsageSummary.line(provider: "Claude", usage: old, now: now, calendar: seoul, missingHelp: "").stale)

        let missing = UsageSummary.line(provider: "Claude", usage: nil, now: now, missingHelp: "없음")
        XCTAssertEqual(missing.cells, [])
        XCTAssertEqual(missing.help, "없음")
    }

    func testResetAndAgeText() {
        XCTAssertEqual(UsageSummary.resetText(now.addingTimeInterval(3600), now: now, calendar: seoul), "16:43")
        XCTAssertEqual(UsageSummary.resetText(Date(timeIntervalSince1970: 1_793_082_773), now: now, calendar: seoul), "10/27 15:32")
        XCTAssertEqual(UsageSummary.ageText(30), "방금")
        XCTAssertEqual(UsageSummary.ageText(150), "2분 전")
        XCTAssertEqual(UsageSummary.ageText(3 * 3600 + 5), "3시간 전")
        XCTAssertEqual(UsageSummary.ageText(6 * 86400), "6일 전")
    }

    func testFileLocations() {
        let env = ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/c"]
        XCTAssertEqual(PlanUsageFiles.ccDash(environment: env).map(\.path), ["/c/cc-dash/usage.json", "/h/.claude/cc-dash/usage.json"])
        XCTAssertEqual(PlanUsageFiles.ccDash(environment: ["HOME": "/h"]).map(\.path), ["/h/.claude/cc-dash/usage.json"])
        XCTAssertEqual(PlanUsageFiles.claudeConfig(environment: env).path, "/c/.claude.json")
        XCTAssertEqual(PlanUsageFiles.claudeConfig(environment: ["HOME": "/h"]).path, "/h/.claude.json")
        let days = PlanUsageFiles.codexDayFolders(home: URL(fileURLWithPath: "/x"),
                                                  now: Date(timeIntervalSince1970: 1_792_515_600), calendar: seoul) // 10/21 02:00 KST
        XCTAssertEqual(days.map(\.path), ["/x/sessions/2026/10/21", "/x/sessions/2026/10/20"])
    }

    func testTailReadsOnlyEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-usage-\(UUID().uuidString).jsonl")
        try Data("0123456789".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(PlanUsageFiles.tail(url, bytes: 4), Data("6789".utf8))
        XCTAssertEqual(PlanUsageFiles.tail(url, bytes: 100), Data("0123456789".utf8))
    }
}
