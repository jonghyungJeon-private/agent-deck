import Foundation

/// 요금제 사용량 한 창(5시간·주간): 쓴 비율과 초기화 시각
public struct UsageWindow: Equatable {
    public var percent: Double
    public var resetsAt: Date?
    public init(percent: Double, resetsAt: Date?) { self.percent = percent; self.resetsAt = resetsAt }
}

/// Claude Code·Codex 가 남긴 파일에서 읽은 사용량(읽기만 — 토큰·API 를 쓰지 않는다)
public struct PlanUsage: Equatable {
    public enum Source: String {
        case codexRollout = "Codex 세션 기록"
        case ccDash = "cc-dash 기록"
        case claudeCache = "Claude Code /usage 캐시"
    }
    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    /// 이 값을 기록한 시각
    public var recordedAt: Date
    public var source: Source
    public init(fiveHour: UsageWindow?, weekly: UsageWindow?, recordedAt: Date, source: Source) {
        self.fiveHour = fiveHour; self.weekly = weekly; self.recordedAt = recordedAt; self.source = source
    }
}

public enum PlanUsageParser {
    /// Codex rollout 끝부분에서 마지막 `rate_limits`(limit_id "codex")를 찾는다. 첫 줄은 잘렸을 수 있어 해석 실패면 건너뛴다.
    /// 바이트 표시로 먼저 거르므로 rollout 처럼 한 줄 JSON(공백 없음)이어야 한다.
    public static func codexRateLimits(tail: Data, fallbackDate: Date) -> PlanUsage? {
        let marker = Data(#""rate_limits":{"#.utf8)
        var end = tail.endIndex
        while end > tail.startIndex {
            let start = tail[tail.startIndex..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? tail.startIndex
            let line = tail[start..<end]
            end = start > tail.startIndex ? start - 1 : tail.startIndex
            guard line.range(of: marker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            if let id = limits["limit_id"] as? String, id != "codex" { continue }
            let at = (object["timestamp"] as? String).flatMap(isoDate) ?? fallbackDate
            var usage = PlanUsage(fiveHour: nil, weekly: nil, recordedAt: at, source: .codexRollout)
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any], let percent = number(window["used_percent"]) else { continue }
                let reset = number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                    ?? number(window["resets_in_seconds"]).map { at.addingTimeInterval($0) }
                let value = UsageWindow(percent: percent, resetsAt: reset)
                // 창 길이로 나눈다(없으면 primary = 5시간, secondary = 주간)
                let minutes = number(window["window_minutes"]) ?? (key == "primary" ? 300 : 10080)
                if minutes <= 24 * 60 { usage.fiveHour = value } else { usage.weekly = value }
            }
            if usage.fiveHour != nil || usage.weekly != nil { return usage }
        }
        return nil
    }

    /// cc-dash mod 가 쓰는 `cc-dash/usage.json`: {"at":ms,"limits":[{"kind":"five_hour","pct":36,"resetsAt":"ISO"},…]}
    public static func ccDash(_ data: Data) -> PlanUsage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let at = number(object["at"]), let limits = object["limits"] as? [[String: Any]] else { return nil }
        var usage = PlanUsage(fiveHour: nil, weekly: nil, recordedAt: Date(timeIntervalSince1970: at / 1000), source: .ccDash)
        for limit in limits {
            guard let percent = number(limit["pct"]) else { continue }
            let value = UsageWindow(percent: percent, resetsAt: (limit["resetsAt"] as? String).flatMap(isoDate))
            switch limit["kind"] as? String {
            case "five_hour": usage.fiveHour = value
            case "seven_day": usage.weekly = value
            default: break
            }
        }
        return usage.fiveHour != nil || usage.weekly != nil ? usage : nil
    }

    /// Claude Code 가 `.claude.json` 에 남기는 `cachedUsageUtilization`(/usage 를 열 때 받아 둔 값).
    /// 큰 설정 파일 전체를 해석하지 않고 그 객체만 잘라 읽는다.
    public static func claudeCache(configFile data: Data) -> PlanUsage? {
        guard let key = data.range(of: Data(#""cachedUsageUtilization""#.utf8)),
              let fragment = balancedObject(in: data, from: key.upperBound),
              let object = (try? JSONSerialization.jsonObject(with: fragment)) as? [String: Any],
              let at = number(object["fetchedAtMs"]),
              let utilization = object["utilization"] as? [String: Any] else { return nil }
        func window(_ name: String) -> UsageWindow? {
            guard let window = utilization[name] as? [String: Any], let percent = number(window["utilization"]) else { return nil }
            return UsageWindow(percent: percent, resetsAt: (window["resets_at"] as? String).flatMap(isoDate))
        }
        let usage = PlanUsage(fiveHour: window("five_hour"), weekly: window("seven_day"),
                              recordedAt: Date(timeIntervalSince1970: at / 1000), source: .claudeCache)
        return usage.fiveHour != nil || usage.weekly != nil ? usage : nil
    }

    /// `from` 뒤 첫 `{` 부터 짝이 맞는 `}` 까지(문자열 안의 괄호·이스케이프는 무시)
    static func balancedObject(in data: Data, from: Data.Index) -> Data? {
        guard let open = data[from...].firstIndex(of: UInt8(ascii: "{")) else { return nil }
        // 키 바로 뒤(공백·콜론만 사이에)여야 한다
        guard data[from..<open].allSatisfy({ $0 == 0x3A || $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in open..<data.endIndex {
            let byte = data[index]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 { return data[open...index] }
            default: break
            }
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    /// ISO 8601(소수 초 자릿수가 제각각 — "…00.000Z", "…00.090304+00:00")
    public static func isoDate(_ text: String) -> Date? {
        var whole = text, fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix(while: \.isNumber)
            fraction = Double("0." + digits) ?? 0
            whole = String(text[..<dot]) + text[text.index(after: dot)...].dropFirst(digits.count)
        }
        return isoFormatter.date(from: whole)?.addingTimeInterval(fraction)
    }
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// 상태 줄 한 칸의 색 단계: 70% 미만 흐리게, 70~89% 노랑, 90% 이상 빨강
public enum UsageTier: Equatable {
    case normal, warn, critical
    public init(percent: Double) {
        self = percent >= 90 ? .critical : percent >= 70 ? .warn : .normal
    }
}

/// 상태 줄에 그릴 한 칸("5h 36%"). 이미 초기화된 창은 percent 가 nil("—")
public struct UsageCell: Equatable {
    public var label: String
    public var percent: Double?
    public var tier: UsageTier { percent.map(UsageTier.init(percent:)) ?? .normal }
    public var text: String { percent.map { "\(Int($0.rounded()))%" } ?? "—" }
    public init(label: String, percent: Double?) { self.label = label; self.percent = percent }
}

/// 상태 줄 한 줄(공급자 하나). cells 가 비면 정보 없음
public struct UsageLine: Equatable {
    public var provider: String
    public var cells: [UsageCell]
    public var stale: Bool
    public var help: String
}

public enum UsageSummary {
    /// 이보다 오래된 기록은 "오래됨"으로 흐리게
    public static let staleAfter: TimeInterval = 6 * 3600

    public static func line(provider: String, usage: PlanUsage?, now: Date, calendar: Calendar = .current,
                            missingHelp: String) -> UsageLine {
        guard let usage else { return UsageLine(provider: provider, cells: [], stale: false, help: missingHelp) }
        let windows: [(label: String, name: String, window: UsageWindow?)] = [
            ("5h", "5시간 창", usage.fiveHour), ("7d", "주간", usage.weekly),
        ]
        var cells: [UsageCell] = []
        var lines = ["\(provider) 요금제 사용량"]
        for item in windows {
            guard let window = item.window else { continue }
            if let reset = window.resetsAt, reset <= now {
                cells.append(UsageCell(label: item.label, percent: nil))
                lines.append("\(item.name): \(resetText(reset, now: now, calendar: calendar)) 에 초기화됨 — 새 기록 전")
            } else {
                cells.append(UsageCell(label: item.label, percent: window.percent))
                let reset = window.resetsAt.map { " · \(resetText($0, now: now, calendar: calendar)) 초기화" } ?? ""
                lines.append("\(item.name): \(Int(window.percent.rounded()))% 사용\(reset)")
            }
        }
        let age = now.timeIntervalSince(usage.recordedAt)
        let stale = age > staleAfter
        lines.append("\(ageText(age)) 기록 (\(usage.source.rawValue))")
        if stale { lines.append("6시간 넘게 새 기록이 없어 지금과 다를 수 있습니다") }
        return UsageLine(provider: provider, cells: cells, stale: stale, help: lines.joined(separator: "\n"))
    }

    /// 오늘이면 "13:48", 아니면 "10/23 07:00"(지역 시각)
    public static func resetText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return calendar.isDate(date, inSameDayAs: now) ? time : "\(parts.month ?? 0)/\(parts.day ?? 0) \(time)"
    }

    public static func ageText(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        if minutes < 24 * 60 { return "\(minutes / 60)시간 전" }
        return "\(minutes / (24 * 60))일 전"
    }
}

/// 사용량 파일 위치(읽기만)
public enum PlanUsageFiles {
    /// cc-dash 기록: CLAUDE_CONFIG_DIR 쪽 먼저, cc-dash 가 실제로 쓰는 $HOME/.claude 쪽도
    public static func ccDash(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? Paths.home
        var dirs = [home.appendingPathComponent(".claude")]
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            dirs.insert(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath), at: 0)
        }
        var seen = Set<String>()
        return dirs.map { $0.appendingPathComponent("cc-dash/usage.json").standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    /// Claude Code 전역 설정(.claude.json): CLAUDE_CONFIG_DIR 가 있으면 그 안, 없으면 홈($HOME — Claude Code 와 같게)
    public static func claudeConfig(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? Paths.home
        return home.appendingPathComponent(".claude.json")
    }

    /// Codex rollout 날짜 폴더(지역 날짜): 오늘·어제
    public static func codexDayFolders(home: URL = CodexSessions.defaultHome, now: Date = Date(),
                                       calendar: Calendar = .current) -> [URL] {
        [0, -1].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }.map { day in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                                               isDirectory: true)
        }
    }

    /// 파일 끝 bytes 만 읽는다
    public static func tail(_ url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return try? handle.readToEnd()
    }
}
