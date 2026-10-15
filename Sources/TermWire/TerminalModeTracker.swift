/// 터미널 모드 추적기. 데몬이 지난 출력 앞부분을 버릴 때 버린 바이트만 차례로 먹여서,
/// 남은 출력이 시작하는 시점의 모드(대체 화면, 커서 숨김, 키보드·마우스 모드 등)를 기억한다.
/// 앱이 다시 붙을 때 `prefix()` 를 남은 출력 앞에 붙이면, 버려진 `ESC[?1049h` 같은 설정이 되살아난다.
///
/// - 바이트마다 상태 기계 한 걸음(할당 없음). 버린 부분이 시퀀스 중간에서 끝나도 다음 먹이기에서 이어 읽는다.
/// - OSC·DCS·APC·PM·SOS 문자열 안의 글은 무시한다(BEL 또는 ST 로 끝남).
/// - 8비트 C1(0x9b 등)은 UTF-8 한글의 이어지는 바이트와 겹치므로 보지 않는다.
/// - 동기 출력(2026)은 되살리지 않는다(되살리면 화면이 멈춘 채로 남을 수 있다).
public struct TerminalModeTracker: Equatable {
    /// kitty 키보드 플래그 스택 상한
    public static let kittyStackLimit = 8

    /// kitty 키보드 프로토콜 상태(SwiftTerm 과 같은 모델: 지금 플래그 + 밀어 둔 이전 플래그들). 화면(보통·대체)마다 따로.
    public struct KittyKeyboard: Equatable {
        public var flags: Int
        public var stack: [Int]
        public init(flags: Int = 0, stack: [Int] = []) {
            self.flags = flags
            self.stack = stack
        }
        public var isDefault: Bool { flags == 0 && stack.isEmpty }
    }

    public private(set) var altScreen = false
    public private(set) var cursorHidden = false
    /// DECCKM(1)
    public private(set) var applicationCursor = false
    /// 2004
    public private(set) var bracketedPaste = false
    /// 마우스 추적 방식: 0(끔) · 9 · 1000 · 1002 · 1003. 마지막으로 켠 것만 쓰이고 하나라도 끄면 꺼진다(SwiftTerm 과 같다).
    public private(set) var mouseTracking = 0
    /// 마우스 좌표 형식: 0(기본) · 1005 · 1006 · 1015 · 1016
    public private(set) var mouseEncoding = 0
    /// 1004
    public private(set) var focusEvents = false
    public private(set) var kittyNormal = KittyKeyboard()
    public private(set) var kittyAlt = KittyKeyboard()

    /// 대체 화면 켜기·끄기(47/1047/1049)를 처음 만났을 때 그것이 켜기였는지. 아직 없으면 nil.
    public private(set) var firstAltScreenToggle: Bool?

    // MARK: 파서 상태

    private enum State: UInt8 {
        case ground, escape, escapeIntermediate, csi, csiIgnore, string, stringEscape
    }

    private var state = State.ground
    /// CSI 의 앞 표시('?', '>', '<', '=') — 없으면 0
    private var marker: UInt8 = 0
    private var intermediate = false
    private var params = ParamBuffer()

    public init() {}

    // MARK: 먹이기

    public mutating func feed(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBufferPointer { buffer in
            for byte in buffer { step(byte) }
        }
    }

    public mutating func feed(_ bytes: [UInt8]) { feed(bytes[...]) }

    /// 바이트 열에서 대체 화면 켜기·끄기를 처음 만나는 곳을 찾는다(true = 켜기, false = 끄기, 없으면 nil).
    /// 앱이 예전 데몬(앞 모드를 붙여 주지 않음)의 지난 출력을 받았을 때 시작 상태를 짐작하는 데 쓴다.
    public static func firstAltScreenToggle(in bytes: ArraySlice<UInt8>) -> Bool? {
        var tracker = TerminalModeTracker()
        return bytes.withUnsafeBufferPointer { buffer in
            for byte in buffer {
                tracker.step(byte)
                if let toggle = tracker.firstAltScreenToggle { return toggle }
            }
            return nil
        }
    }

    @inline(__always)
    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1b { state = .escape }
        case .escape:
            escape(byte)
        case .escapeIntermediate:
            if byte == 0x1b {
                state = .escape
            } else if byte >= 0x30 && byte <= 0x7e || byte == 0x18 || byte == 0x1a {
                state = .ground
            }
        case .csi, .csiIgnore:
            csi(byte)
        case .string:
            if byte == 0x07 || byte == 0x18 || byte == 0x1a {
                state = .ground
            } else if byte == 0x1b {
                state = .stringEscape
            }
        case .stringEscape:
            // ESC \ = ST. 다른 글자면 xterm 처럼 문자열을 끝내고 그 ESC 를 새 시퀀스의 시작으로 본다.
            if byte == 0x5c {
                state = .ground
            } else {
                escape(byte)
            }
        }
    }

    @inline(__always)
    private mutating func escape(_ byte: UInt8) {
        switch byte {
        case 0x5b: // [
            state = .csi
            marker = 0
            intermediate = false
            params.reset()
        case 0x5d, 0x50, 0x5f, 0x5e, 0x58: // ] P _ ^ X — OSC DCS APC PM SOS
            state = .string
        case 0x63: // c — RIS(완전 초기화)
            reset()
            state = .ground
        case 0x1b:
            state = .escape
        case 0x20...0x2f:
            state = .escapeIntermediate
        case 0x18, 0x1a:
            state = .ground
        case 0x00...0x1f:
            break // ESC 안의 C0 는 실행만 하고 시퀀스는 이어진다
        default:
            state = .ground
        }
    }

    @inline(__always)
    private mutating func csi(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            if intermediate { state = .csiIgnore } else { params.digit(byte) }
        case 0x3b, 0x3a: // ; :
            if intermediate { state = .csiIgnore } else { params.separator() }
        case 0x3c...0x3f: // < = > ?
            if marker == 0 && params.isEmpty && !intermediate { marker = byte } else { state = .csiIgnore }
        case 0x20...0x2f:
            intermediate = true
        case 0x40...0x7e:
            let ignored = state == .csiIgnore || intermediate
            state = .ground
            if !ignored { dispatch(final: byte) }
        case 0x1b:
            state = .escape
        case 0x18, 0x1a:
            state = .ground
        default:
            break // 그 밖의 C0 는 실행만(상태 그대로), 0x7f 이상은 무시
        }
    }

    private mutating func dispatch(final: UInt8) {
        switch (marker, final) {
        case (0x3f, 0x68), (0x3f, 0x6c): // ? h / ? l
            let set = final == 0x68
            for index in 0..<params.count { privateMode(params[index], set: set) }
        case (0x3e, 0x75): // > u — push
            let flags = params.count > 0 ? params[0] : 0
            updateKitty { kitty in
                if kitty.stack.count >= Self.kittyStackLimit { kitty.stack.removeFirst() }
                kitty.stack.append(kitty.flags)
                kitty.flags = flags
            }
        case (0x3c, 0x75): // < u — pop
            let count = max(params.count > 0 ? params[0] : 1, 1)
            updateKitty { kitty in
                if count > kitty.stack.count {
                    kitty = KittyKeyboard()
                } else {
                    for _ in 0..<count { kitty.flags = kitty.stack.removeLast() }
                }
            }
        case (0x3d, 0x75): // = u — set
            let flags = params.count > 0 ? params[0] : 0
            let mode = params.count > 1 ? params[1] : 1
            updateKitty { kitty in
                switch mode {
                case 1: kitty.flags = flags
                case 2: kitty.flags |= flags
                case 3: kitty.flags &= ~flags
                default: break
                }
            }
        default:
            break
        }
    }

    private mutating func privateMode(_ mode: Int, set: Bool) {
        switch mode {
        case 47, 1047, 1049:
            altScreen = set
            if firstAltScreenToggle == nil { firstAltScreenToggle = set }
        case 25:
            cursorHidden = !set
        case 1:
            applicationCursor = set
        case 2004:
            bracketedPaste = set
        case 9, 1000, 1002, 1003:
            mouseTracking = set ? mode : 0
        case 1005, 1006, 1015, 1016:
            mouseEncoding = set ? mode : 0
        case 1004:
            focusEvents = set
        default:
            break
        }
    }

    private mutating func updateKitty(_ update: (inout KittyKeyboard) -> Void) {
        if altScreen { update(&kittyAlt) } else { update(&kittyNormal) }
    }

    private mutating func reset() {
        let first = firstAltScreenToggle
        self = TerminalModeTracker()
        firstAltScreenToggle = first
    }

    // MARK: 되살리기

    /// 기본값과 다른 모드만 되살리는 바이트. 모두 기본값이면 빈 배열.
    /// 순서: 보통 화면의 kitty 스택 → 대체 화면 → 대체 화면의 kitty 스택 → 커서 숨김 등
    /// (대체 화면 켜기가 커서를 다시 보이게 하므로 커서 숨김은 그 뒤에 둔다).
    public func prefix() -> [UInt8] {
        var out: [UInt8] = []
        func csi(_ body: String) { out.append(contentsOf: [0x1b, 0x5b]); out.append(contentsOf: body.utf8) }
        func kitty(_ state: KittyKeyboard) {
            guard !state.isDefault else { return }
            // 기본 상태(플래그 0, 빈 스택)에서: 맨 아래 값은 '설정'으로, 나머지는 차례로 밀어 넣는다
            let values = state.stack + [state.flags]
            if values[0] != 0 { csi("=\(values[0]);1u") }
            for value in values.dropFirst() { csi(">\(value)u") }
        }
        kitty(kittyNormal)
        if altScreen {
            csi("?1049h")
            kitty(kittyAlt)
        }
        if cursorHidden { csi("?25l") }
        if applicationCursor { csi("?1h") }
        if bracketedPaste { csi("?2004h") }
        if mouseTracking != 0 { csi("?\(mouseTracking)h") }
        if mouseEncoding != 0 { csi("?\(mouseEncoding)h") }
        if focusEvents { csi("?1004h") }
        return out
    }
}

/// CSI 숫자 인자(고정 크기, 할당 없음). 넘치는 인자·큰 수는 잘라 낸다.
private struct ParamBuffer: Equatable {
    static let capacity = 16
    private var values: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    /// 끝난 인자 수 + 지금 쓰는 인자(있으면 1)
    private(set) var count = 0
    private var open = false

    static func == (lhs: ParamBuffer, rhs: ParamBuffer) -> Bool {
        guard lhs.count == rhs.count, lhs.open == rhs.open else { return false }
        return (0..<lhs.count).allSatisfy { lhs[$0] == rhs[$0] }
    }

    var isEmpty: Bool { count == 0 }

    mutating func reset() {
        count = 0
        open = false
    }

    mutating func digit(_ byte: UInt8) {
        if !open {
            guard count < Self.capacity else { return }
            set(count, 0)
            count += 1
            open = true
        }
        let current = self[count - 1]
        if current < 100_000 { set(count - 1, current * 10 + Int(byte - 0x30)) }
    }

    mutating func separator() {
        if !open {
            // 빈 인자(";1" 의 앞)는 0
            guard count < Self.capacity else { return }
            set(count, 0)
            count += 1
        }
        open = false
    }

    subscript(index: Int) -> Int {
        withUnsafeBytes(of: values) { $0.load(fromByteOffset: index * MemoryLayout<Int>.stride, as: Int.self) }
    }

    private mutating func set(_ index: Int, _ value: Int) {
        withUnsafeMutableBytes(of: &values) { $0.storeBytes(of: value, toByteOffset: index * MemoryLayout<Int>.stride, as: Int.self) }
    }
}
