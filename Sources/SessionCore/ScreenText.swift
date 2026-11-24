import Foundation

/// 데몬이 보관한 지난 출력(replay)을 화면 격자에 그려 글로 읽는다. `agentdeck read` 용.
/// 색 코드만 지우면 claude·codex 처럼 줄을 지우고 다시 그리는 화면은 같은 줄이 겹쳐 나오므로, 커서 이동·지우기·스크롤을
/// 따라가는 작은 터미널 흉내를 둔다(색·글꼴·마우스 같은 것은 무시). 앱의 터미널 엔진(SwiftTerm)은 AppKit 을 끌고 와서
/// hook 마다 뜨는 데몬 실행 파일에 넣지 않았다.
public struct ScreenText {
    public private(set) var cols: Int
    public private(set) var rows: Int
    private let scrollbackLimit: Int

    /// [바깥 화면, 대체 화면]. 격자를 제자리에서 고치려고 (계산 속성이 아니라) 배열로 둔다.
    private var grids: [[[Character]]]
    private var scrollback: [[Character]] = []
    private var useAlt = false
    private var cur: Int { useAlt ? 1 : 0 }
    private var x = 0
    private var y = 0
    private var wrapPending = false
    private var saved: (x: Int, y: Int) = (0, 0)
    private var top = 0
    private var bottom: Int

    private enum Mode { case ground, escape, csi, string, stringEscape, charset }
    private var mode = Mode.ground
    private var params = ""
    private var pendingUTF8: [UInt8] = []
    private var pendingLength = 0

    private static let blank: Character = " "
    /// 넓은 글자의 뒤 칸 표시(글로 낼 때 건너뛴다)
    private static let filler: Character = "\u{0}"

    public init(cols: Int, rows: Int, scrollbackLimit: Int = 4000) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 2)
        self.scrollbackLimit = scrollbackLimit
        grids = [Self.grid(self.cols, self.rows), Self.grid(self.cols, self.rows)]
        bottom = self.rows - 1
    }

    private static func grid(_ cols: Int, _ rows: Int) -> [[Character]] {
        Array(repeating: Array(repeating: blank, count: cols), count: rows)
    }

    // MARK: - 읽기

    /// 지금 보이는 글(바깥 화면이면 지나간 줄 포함). 줄 끝 공백과 끝의 빈 줄은 뺀다.
    public var lines: [String] {
        var rowsOut = useAlt ? grids[1] : scrollback + grids[0]
        while let last = rowsOut.last, Self.text(of: last).isEmpty { rowsOut.removeLast() }
        return rowsOut.map(Self.text(of:))
    }

    public func tail(_ count: Int) -> [String] {
        Array(lines.suffix(max(count, 0)))
    }

    private static func text(of row: [Character]) -> String {
        var chars = row.filter { $0 != filler }
        while chars.last == blank { chars.removeLast() }
        return String(chars)
    }

    // MARK: - 먹이기

    public mutating func feed(_ bytes: [UInt8]) {
        for byte in bytes { feed(byte) }
    }

    private mutating func feed(_ byte: UInt8) {
        if pendingLength > 0 {
            if byte & 0xC0 == 0x80 {
                pendingUTF8.append(byte)
                if pendingUTF8.count == pendingLength {
                    let text = String(decoding: pendingUTF8, as: UTF8.self)
                    pendingUTF8 = []
                    pendingLength = 0
                    for scalar in text.unicodeScalars { put(scalar) }
                }
                return
            }
            pendingUTF8 = [] // 잘린 글자는 버리고 이 바이트부터 다시
            pendingLength = 0
        }
        switch mode {
        case .ground: ground(byte)
        case .escape: escape(byte)
        case .csi: csi(byte)
        case .string:
            if byte == 0x07 { mode = .ground } else if byte == 0x1b { mode = .stringEscape }
        case .stringEscape:
            mode = byte == 0x5c ? .ground : .string // ESC \ = 끝
        case .charset:
            mode = .ground // ESC ( B 같은 글자 집합 지정의 마지막 글자
        }
    }

    private mutating func ground(_ byte: UInt8) {
        switch byte {
        case 0x1b: mode = .escape
        case 0x0a, 0x0b, 0x0c: lineFeed()
        case 0x0d: x = 0; wrapPending = false
        case 0x08: if x > 0 { x -= 1 }; wrapPending = false
        case 0x09: x = min(((x / 8) + 1) * 8, cols - 1); wrapPending = false
        case 0x00..<0x20, 0x7f: break
        case 0x20..<0x7f: put(Unicode.Scalar(byte))
        case 0xC2...0xF4:
            pendingUTF8 = [byte]
            pendingLength = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
        default: break
        }
    }

    private mutating func escape(_ byte: UInt8) {
        mode = .ground
        switch byte {
        case 0x5b: mode = .csi; params = "" // [
        case 0x5d, 0x50, 0x5f, 0x5e, 0x58: mode = .string // ] P _ ^ X: OSC·DCS·APC·PM·SOS
        case 0x28, 0x29, 0x2a, 0x2b, 0x23, 0x25: mode = .charset // ( ) * + # %
        case 0x37: saved = (x, y) // 7
        case 0x38: x = min(saved.x, cols - 1); y = min(saved.y, rows - 1); wrapPending = false // 8
        case 0x4d: reverseIndex() // M
        case 0x44: lineFeed() // D
        case 0x45: x = 0; lineFeed() // E
        case 0x63: reset() // c
        default: break
        }
    }

    private mutating func csi(_ byte: UInt8) {
        if byte >= 0x30 && byte <= 0x3f { // 숫자 ; ? > = <
            params.append(Character(Unicode.Scalar(byte)))
            return
        }
        if byte >= 0x20 && byte <= 0x2f { return } // 중간 글자(공백 등)는 건너뛴다
        mode = .ground
        guard byte >= 0x40 && byte <= 0x7e else { return }
        handleCSI(final: Character(Unicode.Scalar(byte)))
    }

    private func number(_ index: Int, default fallback: Int) -> Int {
        let clean = params.filter { $0.isNumber || $0 == ";" }
        let parts = clean.split(separator: ";", omittingEmptySubsequences: false)
        guard index < parts.count, let value = Int(parts[index]) else { return fallback }
        return value
    }

    private mutating func handleCSI(final: Character) {
        let privateMode = params.hasPrefix("?")
        let n = max(number(0, default: 1), 1)
        switch final {
        case "A": y = max(y - n, y >= top ? top : 0); wrapPending = false
        case "B": y = min(y + n, y <= bottom ? bottom : rows - 1); wrapPending = false
        case "C": x = min(x + n, cols - 1); wrapPending = false
        case "D": x = max(x - n, 0); wrapPending = false
        case "E": x = 0; y = min(y + n, rows - 1); wrapPending = false
        case "F": x = 0; y = max(y - n, 0); wrapPending = false
        case "G": x = min(max(number(0, default: 1), 1) - 1, cols - 1); wrapPending = false
        case "H", "f":
            y = min(max(number(0, default: 1), 1) - 1, rows - 1)
            x = min(max(number(1, default: 1), 1) - 1, cols - 1)
            wrapPending = false
        case "d": y = min(max(number(0, default: 1), 1) - 1, rows - 1); wrapPending = false
        case "J": eraseDisplay(number(0, default: 0))
        case "K": eraseLine(number(0, default: 0))
        case "L": insertLines(n)
        case "M": deleteLines(n)
        case "P": deleteChars(n)
        case "@": insertChars(n)
        case "X": for i in x..<min(x + n, cols) { grids[cur][y][i] = Self.blank }
        case "S": for _ in 0..<n { scrollUp() }
        case "T": for _ in 0..<n { scrollDown() }
        case "r":
            let t = max(number(0, default: 1), 1) - 1
            let b = min(number(1, default: rows), rows) - 1
            if t < b { top = t; bottom = b } else { top = 0; bottom = rows - 1 }
            x = 0; y = 0; wrapPending = false
        case "s": saved = (x, y)
        case "u": x = min(saved.x, cols - 1); y = min(saved.y, rows - 1); wrapPending = false
        case "h", "l":
            guard privateMode else { return }
            let set = final == "h"
            for code in params.dropFirst().split(separator: ";").compactMap({ Int($0) }) where [47, 1047, 1049].contains(code) {
                switchAlt(set, saveCursor: code == 1049)
            }
        default: break // m(색)·기타는 글과 상관없다
        }
    }

    private mutating func switchAlt(_ on: Bool, saveCursor: Bool) {
        guard on != useAlt else { return }
        if on {
            if saveCursor { saved = (x, y) }
            useAlt = true
            grids[1] = Self.grid(cols, rows)
            x = 0; y = 0
        } else {
            useAlt = false
            if saveCursor { x = min(saved.x, cols - 1); y = min(saved.y, rows - 1) }
        }
        wrapPending = false
        top = 0; bottom = rows - 1
    }

    private mutating func reset() {
        grids = [Self.grid(cols, rows), Self.grid(cols, rows)]
        useAlt = false; x = 0; y = 0; top = 0; bottom = rows - 1; wrapPending = false
    }

    // MARK: - 글자·줄

    private static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x300 { return 1 }
        if (0x300...0x36F).contains(v) || (0x200B...0x200F).contains(v) || (0xFE00...0xFE0F).contains(v) || v == 0x20E3 { return 0 }
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v)
            || (0x20000...0x3FFFD).contains(v) { return 2 }
        return 1
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        let w = Self.width(of: scalar)
        if w == 0 {
            // 결합 글자·변형 선택자는 앞 글자에 붙인다
            let px = wrapPending ? x : x - 1
            if px >= 0, grids[cur][y][px] != Self.blank, grids[cur][y][px] != Self.filler {
                grids[cur][y][px] = Character(String(grids[cur][y][px]) + String(scalar))
            }
            return
        }
        if wrapPending || x + w > cols {
            x = 0
            lineFeed()
            wrapPending = false
        }
        grids[cur][y][x] = Character(scalar)
        if w == 2 { grids[cur][y][x + 1] = Self.filler }
        x += w
        if x >= cols { x = cols - 1; wrapPending = true }
    }

    private mutating func lineFeed() {
        wrapPending = false
        if y == bottom {
            scrollUp()
        } else if y < rows - 1 {
            y += 1
        }
    }

    private mutating func reverseIndex() {
        if y == top { scrollDown() } else if y > 0 { y -= 1 }
    }

    private mutating func scrollUp() {
        var grid = grids[cur]
        let line = grid.remove(at: top)
        grid.insert(Array(repeating: Self.blank, count: cols), at: bottom)
        grids[cur] = grid
        if !useAlt, top == 0 {
            scrollback.append(line)
            if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
        }
    }

    private mutating func scrollDown() {
        var grid = grids[cur]
        grid.remove(at: bottom)
        grid.insert(Array(repeating: Self.blank, count: cols), at: top)
        grids[cur] = grid
    }

    private mutating func insertLines(_ n: Int) {
        guard y >= top, y <= bottom else { return }
        var grid = grids[cur]
        for _ in 0..<min(n, bottom - y + 1) {
            grid.remove(at: bottom)
            grid.insert(Array(repeating: Self.blank, count: cols), at: y)
        }
        grids[cur] = grid
    }

    private mutating func deleteLines(_ n: Int) {
        guard y >= top, y <= bottom else { return }
        var grid = grids[cur]
        for _ in 0..<min(n, bottom - y + 1) {
            grid.remove(at: y)
            grid.insert(Array(repeating: Self.blank, count: cols), at: bottom)
        }
        grids[cur] = grid
    }

    private mutating func deleteChars(_ n: Int) {
        var row = grids[cur][y]
        row.removeSubrange(x..<min(x + n, cols))
        row.append(contentsOf: Array(repeating: Self.blank, count: cols - row.count))
        grids[cur][y] = row
    }

    private mutating func insertChars(_ n: Int) {
        var row = grids[cur][y]
        row.insert(contentsOf: Array(repeating: Self.blank, count: min(n, cols - x)), at: x)
        grids[cur][y] = Array(row.prefix(cols))
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 0: for i in x..<cols { grids[cur][y][i] = Self.blank }
        case 1: for i in 0...min(x, cols - 1) { grids[cur][y][i] = Self.blank }
        default: grids[cur][y] = Array(repeating: Self.blank, count: cols)
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            if y + 1 < rows { for r in (y + 1)..<rows { grids[cur][r] = Array(repeating: Self.blank, count: cols) } }
        case 1:
            eraseLine(1)
            for r in 0..<y { grids[cur][r] = Array(repeating: Self.blank, count: cols) }
        case 2:
            grids[cur] = Self.grid(cols, rows)
        default:
            scrollback = []
        }
    }
}
