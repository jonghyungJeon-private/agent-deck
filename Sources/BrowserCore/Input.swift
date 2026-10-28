import CoreGraphics

/// 사람 입력 → CDP `Input.*` 매개변수(화면 없는 부분). 좌표는 이미 CSS 픽셀로 바꾼 것을 받는다(ViewportTransform).
public enum BrowserInput {
    /// CDP 수정 키 비트
    public struct Modifiers: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let alt = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let meta = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public enum Button: String {
        case none, left, right, middle

        /// 누르고 있는 버튼 비트(끌기 중 `buttons`)
        var bit: Int {
            switch self {
            case .none: return 0
            case .left: return 1
            case .right: return 2
            case .middle: return 4
            }
        }
    }

    public enum MouseKind: String {
        case pressed = "mousePressed"
        case released = "mouseReleased"
        case moved = "mouseMoved"
    }

    /// `Input.dispatchMouseEvent`. 끌기(누른 채 움직임)는 moved + 누른 버튼.
    public static func mouse(_ kind: MouseKind, at point: CGPoint, button: Button, clickCount: Int = 1,
                             modifiers: Modifiers = []) -> [String: Any] {
        [
            "type": kind.rawValue, "x": point.x, "y": point.y, "button": button.rawValue,
            "buttons": kind == .released ? 0 : button.bit,
            "clickCount": kind == .moved ? 0 : clickCount, "modifiers": modifiers.rawValue,
        ]
    }

    /// 한 줄 휠(정밀하지 않은 휠 마우스)의 픽셀
    static let lineHeight: CGFloat = 40

    /// `Input.dispatchMouseEvent` mouseWheel. AppKit 의 scrollingDelta 는 내용이 움직이는 쪽(위로 올리면 +),
    /// CDP 의 delta 는 스크롤하는 쪽(아래로 +)이라 부호를 바꾼다. 정밀하지 않으면 줄 단위 → 픽셀.
    public static func wheel(at point: CGPoint, scrollingDeltaX dx: CGFloat, scrollingDeltaY dy: CGFloat, precise: Bool,
                             modifiers: Modifiers = []) -> [String: Any] {
        let scale = precise ? 1 : lineHeight
        return [
            "type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": -dx * scale, "deltaY": -dy * scale,
            "modifiers": modifiers.rawValue,
        ]
    }

    /// DOM 키 이름·코드·Windows 가상 키 코드(Chrome 이 keydown 의 keyCode 로 쓴다)
    public struct Key: Equatable {
        public let key: String
        public let code: String
        public let virtualKeyCode: Int
        /// 이 키가 넣는 글자(Enter 의 "\r" — 있어야 폼 제출 등 기본 동작이 일어난다)
        public let text: String?
    }

    public static let enter = Key(key: "Enter", code: "Enter", virtualKeyCode: 13, text: "\r")
    public static let tab = Key(key: "Tab", code: "Tab", virtualKeyCode: 9, text: nil)
    public static let backspace = Key(key: "Backspace", code: "Backspace", virtualKeyCode: 8, text: nil)
    public static let delete = Key(key: "Delete", code: "Delete", virtualKeyCode: 46, text: nil)
    public static let escape = Key(key: "Escape", code: "Escape", virtualKeyCode: 27, text: nil)
    public static let left = Key(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37, text: nil)
    public static let up = Key(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38, text: nil)
    public static let right = Key(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39, text: nil)
    public static let down = Key(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40, text: nil)
    public static let home = Key(key: "Home", code: "Home", virtualKeyCode: 36, text: nil)
    public static let end = Key(key: "End", code: "End", virtualKeyCode: 35, text: nil)
    public static let pageUp = Key(key: "PageUp", code: "PageUp", virtualKeyCode: 33, text: nil)
    public static let pageDown = Key(key: "PageDown", code: "PageDown", virtualKeyCode: 34, text: nil)

    /// 입력기가 글자 대신 보내는 편집 명령(Cocoa 선택자, `doCommand(by:)`) → 누를 키.
    /// 편집 명령 이름은 그대로 `commands` 로도 보낸다 — Chrome 은 합성된 키 조합을 macOS 편집 명령으로 바꾸지 않으므로
    /// (예: ⌥⌫ 의 단어 지우기는 `deleteWordBackward` 를 같이 줘야 일어난다). 이름에 AndModifySelection 이 붙으면 Shift.
    public static func command(selector: String) -> (key: Key, modifiers: Modifiers, commands: [String])? {
        var name = selector.hasSuffix(":") ? String(selector.dropLast()) : selector
        var modifiers: Modifiers = []
        let editing = name
        if name.hasSuffix("AndModifySelection") {
            name = String(name.dropLast("AndModifySelection".count))
            modifiers.insert(.shift)
        }
        let table: [String: (Key, Modifiers)] = [
            "insertNewline": (enter, []), "insertLineBreak": (enter, []), "insertNewlineIgnoringFieldEditor": (enter, []),
            "insertTab": (tab, []), "insertBacktab": (tab, .shift),
            "deleteBackward": (backspace, []), "deleteForward": (delete, []),
            "deleteWordBackward": (backspace, .alt), "deleteWordForward": (delete, .alt),
            "deleteToBeginningOfLine": (backspace, .meta), "deleteToEndOfLine": (delete, .meta),
            "moveLeft": (left, []), "moveRight": (right, []), "moveUp": (up, []), "moveDown": (down, []),
            "moveBackward": (left, []), "moveForward": (right, []),
            "moveWordLeft": (left, .alt), "moveWordRight": (right, .alt),
            "moveWordBackward": (left, .alt), "moveWordForward": (right, .alt),
            "moveToBeginningOfLine": (left, .meta), "moveToLeftEndOfLine": (left, .meta),
            "moveToEndOfLine": (right, .meta), "moveToRightEndOfLine": (right, .meta),
            "moveToBeginningOfDocument": (up, .meta), "moveToEndOfDocument": (down, .meta),
            "moveToBeginningOfParagraph": (up, .alt), "moveToEndOfParagraph": (down, .alt),
            "scrollPageUp": (pageUp, []), "scrollPageDown": (pageDown, []), "pageUp": (pageUp, []), "pageDown": (pageDown, []),
            "scrollToBeginningOfDocument": (home, []), "scrollToEndOfDocument": (end, []),
            "cancelOperation": (escape, []),
        ]
        guard let (key, extra) = table[name] else { return nil }
        // 줄바꿈·탭·Esc 는 DOM 키 이벤트로만(폼 제출·포커스 이동·닫기 같은 페이지 동작), 페이지·스크롤 키는 Chrome 의
        // 편집 명령 이름이 Cocoa 선택자와 달라(예: MovePageUp) 키의 기본 동작에 맡긴다 — 편집 명령은 붙이지 않는다
        let plain: Set<String> = ["insertNewline", "insertLineBreak", "insertNewlineIgnoringFieldEditor", "insertTab", "insertBacktab",
                                  "cancelOperation", "scrollPageUp", "scrollPageDown", "pageUp", "pageDown",
                                  "scrollToBeginningOfDocument", "scrollToEndOfDocument"]
        return (key, modifiers.union(extra), plain.contains(name) ? [] : [editing])
    }

    /// 키 하나를 누르고 떼는 `Input.dispatchKeyEvent` 두 개. 글자가 있으면 keyDown(글자 입력), 없으면 rawKeyDown.
    public static func press(_ key: Key, modifiers: Modifiers = [], commands: [String] = []) -> [[String: Any]] {
        var down: [String: Any] = [
            "type": key.text == nil ? "rawKeyDown" : "keyDown", "key": key.key, "code": key.code,
            "windowsVirtualKeyCode": key.virtualKeyCode, "modifiers": modifiers.rawValue,
        ]
        if let text = key.text { down["text"] = text; down["unmodifiedText"] = text }
        if !commands.isEmpty { down["commands"] = commands }
        let up: [String: Any] = [
            "type": "keyUp", "key": key.key, "code": key.code, "windowsVirtualKeyCode": key.virtualKeyCode,
            "modifiers": modifiers.rawValue,
        ]
        return [down, up]
    }

    /// macOS 물리 키 번호(NSEvent.keyCode, ANSI 자판 위치) → DOM `code` 와 Windows 가상 키 코드.
    /// 글자가 아니라 자리라서 Shift·자판 배열과 상관없다(페이지의 `event.code`·단축키가 쓴다).
    public static func physical(keyCode: UInt16) -> (code: String, virtualKeyCode: Int)? {
        let letters: [UInt16: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
                                         12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
                                         37: "L", 38: "J", 40: "K", 45: "N", 46: "M"]
        if let l = letters[keyCode] { return ("Key" + l, Int(l.unicodeScalars.first!.value)) }
        let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if let d = digits[keyCode] { return ("Digit\(d)", 48 + d) }
        let others: [UInt16: (String, Int)] = [
            49: ("Space", 32), 24: ("Equal", 187), 27: ("Minus", 189), 33: ("BracketLeft", 219), 30: ("BracketRight", 221),
            39: ("Quote", 222), 41: ("Semicolon", 186), 42: ("Backslash", 220), 43: ("Comma", 188), 44: ("Slash", 191),
            47: ("Period", 190), 50: ("Backquote", 192),
        ]
        return others[keyCode]
    }

    /// 글자 하나 키(입력기 없이 친 영문·숫자·기호): keydown·keypress·input 이 모두 일어나게 키 이벤트로 보낸다.
    /// 수정 키(Shift 포함)는 그대로 둔다 — 글자("A")와 Shift 는 따로 전하는 정보다. 여러 글자(입력기 확정·붙여넣기)는 nil.
    public static func character(_ text: String, keyCode: UInt16? = nil, modifiers: Modifiers = []) -> [[String: Any]]? {
        guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII, scalar.value >= 0x20, scalar.value != 0x7f
        else { return nil }
        let place = keyCode.flatMap(physical(keyCode:))
        let vk: Int
        if let place {
            vk = place.virtualKeyCode
        } else if let u = Character(text).uppercased().unicodeScalars.first, Character(text).uppercased().count == 1,
                  ("A"..."Z").contains(Character(u)) || ("0"..."9").contains(Character(u)) {
            vk = Int(u.value)
        } else {
            vk = text == " " ? 32 : 0
        }
        let key = Key(key: text, code: place?.code ?? "", virtualKeyCode: vk, text: text)
        return press(key, modifiers: modifiers)
    }

    /// ⌘ 편집 단축키 → 편집 명령을 붙인 키(전체 선택·되돌리기 등)
    public static func shortcut(_ command: String) -> [[String: Any]]? {
        let keys: [String: (String, Modifiers)] = [
            "selectAll": ("a", .meta), "undo": ("z", .meta), "redo": ("z", [.meta, .shift]),
            "cut": ("x", .meta), "copy": ("c", .meta), "paste": ("v", .meta),
        ]
        guard let (letter, modifiers) = keys[command] else { return nil }
        let key = Key(key: letter, code: "Key" + letter.uppercased(), virtualKeyCode: Int(letter.uppercased().unicodeScalars.first!.value), text: nil)
        return press(key, modifiers: modifiers, commands: [command])
    }
}
