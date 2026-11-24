import Foundation

/// 칸에 글을 입력할 때의 바이트와 순서. 여러 줄·긴 글은 bracketed paste 로 보내 claude·codex 가 한 번에 받게 하고,
/// Enter 는 따로(조금 뒤에) 보낸다 — 글과 같은 덩어리로 보내면 입력창이 줄바꿈 글자로 받아 제출되지 않는 일이 있다.
public enum PasteEncoding {
    /// 이 길이(바이트)를 넘는 글은 한 줄이어도 붙여넣기로 보낸다
    public static let longText = 400
    public static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] // ESC [ 200 ~
    public static let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e] // ESC [ 201 ~
    public static let enter: [UInt8] = [0x0d]

    public struct Step: Equatable {
        public var bytes: [UInt8]
        /// 이 조각을 보낸 뒤 기다릴 시간(초)
        public var delayAfter: TimeInterval

        public init(_ bytes: [UInt8], delayAfter: TimeInterval = 0) {
            self.bytes = bytes
            self.delayAfter = delayAfter
        }
    }

    public static func needsPaste(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r") || text.utf8.count > longText
    }

    /// 줄바꿈은 \n 으로 맞추고(\r\n·\r 포함), ESC 와 그 밖의 제어 문자는 뺀다(붙여넣기 끝 표시를 글 안에 심어 빠져나오는 것을 막는다). 탭은 둔다.
    public static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousWasCR = true
                continue
            }
            defer { previousWasCR = false }
            if scalar == "\n" {
                if !previousWasCR { out.append("\n") }
                continue
            }
            if scalar == "\t" { out.append(scalar); continue }
            if scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value) { continue }
            out.append(scalar)
        }
        return String(out)
    }

    /// 이 칸의 글은 한 줄이어도 붙여넣기로 보내야 하는가 — claude·codex 는 입력창이 `!`(셸 모드)·`/`(명령)로 시작하는 글을 그대로 받아
    /// 모드·명령으로 해석한다. 붙여넣기로 받으면 글로만 취급한다. 셸 칸은 지금처럼(붙여넣기로 받으면 셸이 명령으로 실행하지 않는다).
    public static func alwaysPaste(kind: PaneKind) -> Bool { kind != .shell }

    /// 보낼 조각들. bracketedPaste: 그 칸의 프로그램이 붙여넣기 모드(?2004)를 켰는가.
    /// 꺼져 있는데 여러 줄이면 줄바꿈을 Enter(CR)로 바꿔 보낸다(셸이 한 줄씩 실행한다).
    /// alwaysPaste: 한 줄 짧은 글도 (붙여넣기 모드가 켜져 있으면) 붙여넣기로 보낸다(`alwaysPaste(kind:)`).
    public static func plan(text: String, bracketedPaste: Bool, enter sendEnter: Bool, alwaysPaste: Bool = false) -> [Step] {
        var clean = sanitize(text)
        if sendEnter { while clean.hasSuffix("\n") { clean.removeLast() } } // 끝 줄바꿈은 아래 Enter 가 대신한다
        var steps: [Step] = []
        if needsPaste(clean) || (alwaysPaste && bracketedPaste && !clean.isEmpty) {
            if bracketedPaste {
                steps.append(Step(pasteStart + Array(clean.utf8) + pasteEnd, delayAfter: sendEnter ? 0.3 : 0))
            } else {
                steps.append(Step(Array(clean.replacingOccurrences(of: "\n", with: "\r").utf8), delayAfter: sendEnter ? 0.1 : 0))
            }
        } else if !clean.isEmpty {
            steps.append(Step(Array(clean.utf8), delayAfter: sendEnter ? 0.15 : 0))
        }
        if sendEnter { steps.append(Step(enter)) }
        return steps
    }
}
