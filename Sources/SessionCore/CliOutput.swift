import Foundation

/// `agentdeck` 의 사람용 표·글 출력과 시간 읽기(순수 함수 — 시험 가능)
public enum CliOutput {
    /// 터미널에서 차지하는 칸 수(한글·넓은 글자는 2)
    public static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            let v = scalar.value
            if v < 0x300 { return total + 1 }
            if (0x300...0x36F).contains(v) || (0x200B...0x200F).contains(v) || (0xFE00...0xFE0F).contains(v) { return total }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v)
            return total + (wide ? 2 : 1)
        }
    }

    /// 칸 수에 맞춰 뒤를 공백으로 채우고, 넘치면 …로 줄인다
    public static func fit(_ text: String, width: Int) -> String {
        var out = ""
        var used = 0
        for char in text {
            let w = displayWidth(String(char))
            if used + w > width { break }
            out.append(char)
            used += w
        }
        if out.count < text.count, width >= 1 {
            while displayWidth(out) + 1 > width, !out.isEmpty { out.removeLast() }
            out += "…"
            used = displayWidth(out)
        }
        return out + String(repeating: " ", count: max(width - used, 0))
    }

    /// 열 맞춘 표. 머리 줄 + 칸 사이 두 칸 공백, 마지막 칸은 채우지 않는다. maxWidths 는 열별 최대 너비(없으면 제한 없음).
    public static func table(headers: [String], rows: [[String]], maxWidths: [Int?] = []) -> String {
        guard !headers.isEmpty else { return "" }
        let all = [headers] + rows
        var widths = (0..<headers.count).map { column in all.map { displayWidth($0[column]) }.max() ?? 0 }
        for (index, limit) in maxWidths.enumerated() where index < widths.count {
            if let limit { widths[index] = min(widths[index], limit) }
        }
        return all.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : fit(cell, width: widths[index])
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// 기계용 JSON 한 덩어리(키 정렬, 날짜는 ISO-8601, 한글은 그대로)
    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "{}"
    }

    /// 시간 읽기: "90"(초) "90s" "5m" "1h" "1m30s" "1h30m". 0 이하·알 수 없는 글은 nil.
    public static func parseDuration(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        if let plain = Double(text) { return plain > 0 ? plain : nil }
        var total: TimeInterval = 0
        var number = ""
        var matched = false
        for char in text {
            if char.isNumber || char == "." {
                number.append(char)
            } else {
                guard let value = Double(number) else { return nil }
                switch char {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                number = ""
                matched = true
            }
        }
        guard number.isEmpty, matched, total > 0 else { return nil }
        return total
    }
}
