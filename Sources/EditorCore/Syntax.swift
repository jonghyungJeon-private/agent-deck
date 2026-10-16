import Foundation

/// 가벼운 글자 색(IDE 가 아니라 읽기 쉽게만): 키워드·문자열·주석·숫자·타입 정도. 정규식 없이 한 번 훑는다.
public enum SyntaxKind: UInt8, Equatable, Sendable {
    case keyword, string, comment, number, type, attribute, key, heading
}

public struct SyntaxToken: Equatable, Sendable {
    /// UTF-16 위치(NSTextStorage 와 같은 단위)
    public var location: Int
    public var length: Int
    public var kind: SyntaxKind

    public init(_ kind: SyntaxKind, _ location: Int, _ length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// 줄을 넘어 이어지는 상태(줄 시작마다 기억해 두고 거기서부터 다시 훑는다)
public enum ScanState: Hashable, Sendable {
    case normal
    /// 블록 주석 안(겹친 깊이 — Swift·Rust·Kotlin 은 겹칠 수 있다)
    case blockComment(depth: Int)
    /// 여러 줄 문자열 안(닫는 기호, 역슬래시 이스케이프를 쓰는지)
    case string(close: String, escapes: Bool)
    /// Markdown 코드 블록(```) 안
    case fence
}

public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, kotlin, java, typescript, javascript, python, go, rust, json, yaml, toml, markdown, shell, sql

    /// 파일 이름으로 고른다. 모르면 nil(색 없이).
    public static func detect(path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift": return .swift
        case "kt", "kts": return .kotlin
        case "java", "gradle", "groovy", "scala": return .java
        case "ts", "tsx", "mts", "cts": return .typescript
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "py", "pyi": return .python
        case "go": return .go
        case "rs": return .rust
        case "json", "jsonc", "json5", "jsonl": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "md", "markdown", "mdown", "mkd", "mdx": return .markdown
        case "sh", "bash", "zsh", "fish", "command", "ksh": return .shell
        case "sql": return .sql
        default: break
        }
        switch name {
        case ".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile", ".zshenv", ".envrc": return .shell
        case "dockerfile", "makefile": return .shell
        case "cargo.lock", "pipfile", "poetry.lock": return .toml
        case "package.json", ".eslintrc", ".prettierrc", "tsconfig.json": return .json
        default: return nil
        }
    }

    public var spec: SyntaxSpec { SyntaxSpec.make(self) }
}

/// 언어 규칙
public struct SyntaxSpec: Sendable {
    public var language: SyntaxLanguage
    public var keywords: Set<String> = []
    /// 키워드를 대소문자 없이(SQL)
    public var caseInsensitive = false
    public var lineComments: [String] = []
    public var blockComment: (open: String, close: String)?
    public var nestedComments = false
    /// 한 줄 문자열 기호
    public var quotes: Set<UInt16> = []
    /// 여러 줄로 이어지는 문자열(""" ''' ` 등)과 이스케이프 여부
    public var multiline: [(open: String, close: String, escapes: Bool)] = []
    /// 대문자로 시작하는 이름을 타입 색으로
    public var capitalizedTypes = false
    /// @이름(또는 Swift #이름)을 속성 색으로
    public var attributePrefix: Set<UInt16> = []
    /// 셸 변수($이름, ${…})
    public var shellVariables = false
    /// 줄 앞 "이름:"(YAML) / "이름 ="(TOML) 를 키 색으로
    public var lineKeys: UInt16? = nil
    /// 문자열 바로 뒤 ":" 면 키(JSON)
    public var jsonKeys = false
    /// 문자열 안 같은 따옴표 두 번은 이스케이프(SQL '')
    public var doubledQuoteEscape = false
    /// 작은따옴표가 문자 하나일 때만 문자열(Rust 수명 'a 와 구분)
    public var shortCharQuotes = false

    static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    static func make(_ language: SyntaxLanguage) -> SyntaxSpec {
        var s = SyntaxSpec(language: language)
        let dq = UInt16(UInt8(ascii: "\"")), sq = UInt16(UInt8(ascii: "'")), bq = UInt16(UInt8(ascii: "`"))
        let at = UInt16(UInt8(ascii: "@")), hash = UInt16(UInt8(ascii: "#"))
        switch language {
        case .swift:
            s.keywords = words("""
                associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private \
                precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer \
                do else fallthrough for guard if in repeat return throw switch where while as Any false is nil self Self super throws \
                true try async await actor some any weak unowned lazy final override mutating nonmutating convenience required \
                indirect get set willSet didSet consuming borrowing nonisolated isolated package macro
                """)
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.nestedComments = true
            s.quotes = [dq]
            s.multiline = [("\"\"\"", "\"\"\"", true)]
            s.capitalizedTypes = true
            s.attributePrefix = [at, hash]
        case .kotlin:
            s.keywords = words("""
                as break class continue do else false for fun if in interface is null object package return super this throw true \
                try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init \
                param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect \
                external final infix inline inner internal lateinit noinline open operator out override private protected public \
                reified sealed suspend tailrec vararg value
                """)
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.nestedComments = true
            s.quotes = [dq, sq]
            s.multiline = [("\"\"\"", "\"\"\"", false)]
            s.capitalizedTypes = true
            s.attributePrefix = [at]
        case .java:
            s.keywords = words("""
                abstract assert boolean break byte case catch char class const continue default do double else enum extends final \
                finally float for goto if implements import instanceof int interface long native new package private protected public \
                return short static strictfp super switch synchronized this throw throws transient try void volatile while var record \
                sealed permits yield true false null def
                """)
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.quotes = [dq, sq]
            s.multiline = [("\"\"\"", "\"\"\"", true)]
            s.capitalizedTypes = true
            s.attributePrefix = [at]
        case .typescript, .javascript:
            s.keywords = words("""
                break case catch class const continue debugger default delete do else export extends finally for function if import \
                in instanceof new return super switch this throw try typeof var void while with yield let static async await of \
                true false null undefined from as get set
                """)
            if language == .typescript {
                s.keywords.formUnion(words("""
                    interface type enum implements namespace declare abstract readonly private protected public keyof infer is \
                    never unknown any number string boolean symbol bigint object satisfies override module
                    """))
            }
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.quotes = [dq, sq]
            s.multiline = [("`", "`", true)]
            s.capitalizedTypes = true
            s.attributePrefix = [at]
        case .python:
            s.keywords = words("""
                False None True and as assert async await break class continue def del elif else except finally for from global if \
                import in is lambda nonlocal not or pass raise return try while with yield match case self cls
                """)
            s.lineComments = ["#"]
            s.quotes = [dq, sq]
            s.multiline = [("\"\"\"", "\"\"\"", true), ("'''", "'''", true)]
            s.capitalizedTypes = true
            s.attributePrefix = [at]
        case .go:
            s.keywords = words("""
                break case chan const continue default defer else fallthrough for func go goto if import interface map package range \
                return select struct switch type var true false nil iota any error string int int8 int16 int32 int64 uint uint8 \
                uint16 uint32 uint64 uintptr float32 float64 bool byte rune complex64 complex128
                """)
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.quotes = [dq, sq]
            s.multiline = [("`", "`", false)]
            s.capitalizedTypes = true
        case .rust:
            s.keywords = words("""
                as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut \
                pub ref return self Self static struct super trait true type unsafe use where while union macro_rules
                """)
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.nestedComments = true
            s.quotes = [dq, sq]
            s.shortCharQuotes = true
            s.capitalizedTypes = true
            s.attributePrefix = [hash]
        case .json:
            s.keywords = words("true false null")
            s.lineComments = ["//"]
            s.blockComment = ("/*", "*/")
            s.quotes = [dq]
            s.jsonKeys = true
        case .yaml:
            s.keywords = words("true false null yes no on off True False Null Yes No TRUE FALSE NULL ~")
            s.lineComments = ["#"]
            s.quotes = [dq, sq]
            s.lineKeys = UInt16(UInt8(ascii: ":"))
            s.attributePrefix = [UInt16(UInt8(ascii: "&")), UInt16(UInt8(ascii: "*")), UInt16(UInt8(ascii: "!"))]
        case .toml:
            s.keywords = words("true false inf nan")
            s.lineComments = ["#"]
            s.quotes = [dq, sq]
            s.multiline = [("\"\"\"", "\"\"\"", true), ("'''", "'''", false)]
            s.lineKeys = UInt16(UInt8(ascii: "="))
        case .markdown:
            break
        case .shell:
            s.keywords = words("""
                if then else elif fi for while until do done case esac in function select time return local export readonly \
                declare unset source alias exit break continue shift trap eval exec set true false
                """)
            s.lineComments = ["#"]
            s.quotes = [dq, sq]
            s.multiline = [("`", "`", true)]
            s.shellVariables = true
        case .sql:
            s.keywords = words("""
                select from where and or not insert into values update set delete create table drop alter add column index view \
                join inner left right full outer on as group by order having limit offset union all distinct case when then else end \
                null is in like between exists primary key foreign references default unique check constraint with returning begin \
                commit rollback transaction if replace truncate asc desc count sum avg min max cast true false int integer bigint \
                varchar text boolean date timestamp numeric decimal serial
                """)
            s.caseInsensitive = true
            s.lineComments = ["--"]
            s.blockComment = ("/*", "*/")
            s.quotes = [sq, dq]
            s.doubledQuoteEscape = true
        }
        _ = bq
        return s
    }
}

/// 한 번 훑기. 버퍼는 글 전체의 [base, base + count) 부분이고, 시작은 줄 시작이어야 한다(줄 앞 규칙 때문에).
public struct SyntaxScanner {
    public let spec: SyntaxSpec
    private let lineCommentUnits: [[UInt16]]
    private let blockOpen: [UInt16]
    private let blockClose: [UInt16]
    private let multiline: [(open: [UInt16], close: String, escapes: Bool)]

    public init(_ spec: SyntaxSpec) {
        self.spec = spec
        lineCommentUnits = spec.lineComments.map { Array($0.utf16) }
        blockOpen = spec.blockComment.map { Array($0.open.utf16) } ?? []
        blockClose = spec.blockComment.map { Array($0.close.utf16) } ?? []
        multiline = spec.multiline.map { (Array($0.open.utf16), $0.close, $0.escapes) }
    }

    public init(_ language: SyntaxLanguage) { self.init(language.spec) }

    // 자주 쓰는 글자
    private static let newline: UInt16 = 10
    private static let backslash: UInt16 = 92

    private static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }

    private static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }

    /// 훑으며 색 칠할 조각을 emit 으로 알린다. 끝났을 때의 상태를 돌려준다(다음 줄의 시작 상태).
    @discardableResult
    public func scan(_ text: UnsafeBufferPointer<UInt16>, base: Int, state start: ScanState,
                     emit: (SyntaxToken) -> Void) -> ScanState {
        if spec.language == .markdown { return scanMarkdown(text, base: base, state: start, emit: emit) }
        let n = text.count
        var i = 0
        var state = start
        var lineStart = true
        /// 줄에서 처음 보는 글자 앞(공백만 지났음)
        var onlySpaceSoFar = true

        func matches(_ pattern: [UInt16], at index: Int) -> Bool {
            guard !pattern.isEmpty, index + pattern.count <= n else { return false }
            for (offset, unit) in pattern.enumerated() where text[index + offset] != unit { return false }
            return true
        }
        func endOfLine(_ from: Int) -> Int {
            var j = from
            while j < n, text[j] != Self.newline { j += 1 }
            return j
        }
        func token(_ kind: SyntaxKind, _ from: Int, _ to: Int) {
            if to > from { emit(SyntaxToken(kind, base + from, to - from)) }
        }

        while i < n {
            switch state {
            case .blockComment(let depth):
                let from = i
                var level = depth
                while i < n {
                    if matches(blockClose, at: i) {
                        i += blockClose.count
                        level -= 1
                        if level == 0 { break }
                    } else if spec.nestedComments, matches(blockOpen, at: i) {
                        i += blockOpen.count
                        level += 1
                    } else {
                        if text[i] == Self.newline { lineStart = true; onlySpaceSoFar = true }
                        i += 1
                    }
                }
                token(.comment, from, i)
                state = level == 0 ? .normal : .blockComment(depth: level)
                continue
            case .string(let close, let escapes):
                let closeUnits = Array(close.utf16)
                let from = i
                var closed = false
                while i < n {
                    if escapes, text[i] == Self.backslash { i = min(i + 2, n); continue }
                    if matches(closeUnits, at: i) { i += closeUnits.count; closed = true; break }
                    i += 1
                }
                token(.string, from, i)
                state = closed ? .normal : state
                onlySpaceSoFar = false
                continue
            case .fence:
                state = .normal // 마크다운이 아니면 쓰지 않는다
                continue
            case .normal:
                break
            }

            let c = text[i]
            if c == Self.newline {
                i += 1
                lineStart = true
                onlySpaceSoFar = true
                continue
            }
            if Self.isSpace(c) || c == 13 { i += 1; continue }
            let atLineStart = onlySpaceSoFar
            _ = lineStart
            lineStart = false
            onlySpaceSoFar = false

            // 줄 주석(셸 # 은 낱말 시작에서만: $# 나 a#b 는 주석이 아님)
            var isLineComment = false
            for pattern in lineCommentUnits where matches(pattern, at: i) {
                if spec.shellVariables, i > 0, !(Self.isSpace(text[i - 1]) || text[i - 1] == Self.newline || text[i - 1] == 59) {
                    continue
                }
                isLineComment = true
                break
            }
            if isLineComment {
                let end = endOfLine(i)
                token(.comment, i, end)
                i = end
                continue
            }
            // 블록 주석
            if matches(blockOpen, at: i) {
                state = .blockComment(depth: 1)
                let from = i
                i += blockOpen.count
                // 같은 자리에서 이어 훑는다(토큰은 상태 처리에서 한 번에)
                var level = 1
                while i < n {
                    if matches(blockClose, at: i) {
                        i += blockClose.count
                        level -= 1
                        if level == 0 { break }
                    } else if spec.nestedComments, matches(blockOpen, at: i) {
                        i += blockOpen.count
                        level += 1
                    } else {
                        if text[i] == Self.newline { lineStart = true; onlySpaceSoFar = true }
                        i += 1
                    }
                }
                token(.comment, from, i)
                state = level == 0 ? .normal : .blockComment(depth: level)
                continue
            }
            // 여러 줄 문자열
            if let open = multiline.first(where: { matches($0.open, at: i) }) {
                let from = i
                i += open.open.count
                let closeUnits = Array(open.close.utf16)
                var closed = false
                while i < n {
                    if open.escapes, text[i] == Self.backslash { i = min(i + 2, n); continue }
                    if matches(closeUnits, at: i) { i += closeUnits.count; closed = true; break }
                    i += 1
                }
                token(.string, from, i)
                if !closed { state = .string(close: open.close, escapes: open.escapes) }
                continue
            }
            // 한 줄 문자열
            if spec.quotes.contains(c) {
                if spec.shortCharQuotes, c == 39, !isShortChar(text, i) {
                    // Rust 수명('a) — 속성 색으로
                    var j = i + 1
                    while j < n, Self.isIdent(text[j]) { j += 1 }
                    token(.attribute, i, j)
                    i = j
                    continue
                }
                let from = i
                i += 1
                let escapes = !(spec.shellVariables && c == 39) // 셸 작은따옴표 안은 이스케이프 없음
                while i < n, text[i] != Self.newline {
                    if escapes, text[i] == Self.backslash, !spec.doubledQuoteEscape { i = min(i + 2, n); continue }
                    if text[i] == c {
                        if spec.doubledQuoteEscape, i + 1 < n, text[i + 1] == c { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                var kind = SyntaxKind.string
                if spec.jsonKeys || (spec.lineKeys != nil && atLineStart) {
                    var j = i
                    while j < n, Self.isSpace(text[j]) { j += 1 }
                    let separator = spec.lineKeys ?? 58
                    if j < n, text[j] == separator { kind = .key }
                }
                token(kind, from, i)
                continue
            }
            // 줄 앞 키(YAML "이름:", TOML "이름 =") — "- 이름:" 도
            if let separator = spec.lineKeys, atLineStart || (i >= 2 && text[i - 2] == 45 && text[i - 1] == 32 && lineOnlyDash(text, i - 2)) {
                var j = i
                while j < n, Self.isIdent(text[j]) || text[j] == 45 || text[j] == 46 { j += 1 }
                var k = j
                while k < n, Self.isSpace(text[k]) { k += 1 }
                if j > i, k < n, text[k] == separator, separator != 58 || k + 1 >= n || Self.isSpace(text[k + 1]) || text[k + 1] == Self.newline || text[k + 1] == 13 {
                    token(.key, i, j)
                    i = j
                    continue
                }
            }
            // TOML [표]
            if spec.language == .toml, atLineStart, c == 91 {
                let end = endOfLine(i)
                var close = i
                while close < end, text[close] != 93 { close += 1 }
                if close < end, close + 1 < end, text[close + 1] == 93 { close += 1 }
                token(.heading, i, min(close + 1, end))
                i = min(close + 1, end)
                continue
            }
            // 셸 변수
            if spec.shellVariables, c == 36, i + 1 < n {
                var j = i + 1
                if text[j] == 123 { // ${…}
                    while j < n, text[j] != 125, text[j] != Self.newline { j += 1 }
                    if j < n, text[j] == 125 { j += 1 }
                } else {
                    while j < n, Self.isIdent(text[j]) && text[j] != 36 { j += 1 }
                    if j == i + 1, j < n, !Self.isSpace(text[j]), text[j] != Self.newline { j += 1 } // $1 $? $#
                }
                token(.attribute, i, j)
                i = j
                continue
            }
            // 속성(@이름, #이름, Rust #[…])
            if spec.attributePrefix.contains(c), i + 1 < n, Self.isIdentStart(text[i + 1]) || text[i + 1] == 91 {
                var j = i + 1
                if text[j] == 91 {
                    while j < n, text[j] != 93, text[j] != Self.newline { j += 1 }
                    if j < n { j += 1 }
                } else {
                    while j < n, Self.isIdent(text[j]) || text[j] == 46 { j += 1 }
                }
                token(.attribute, i, j)
                i = j
                continue
            }
            // 숫자
            if Self.isDigit(c) || (c == 46 && i + 1 < n && Self.isDigit(text[i + 1]) && (i == 0 || !Self.isIdent(text[i - 1]))) {
                var j = i + 1
                while j < n {
                    let d = text[j]
                    if Self.isIdent(d) || d == 46 {
                        j += 1
                    } else if (d == 43 || d == 45), (text[j - 1] == 101 || text[j - 1] == 69), !(text[i] == 48 && i + 1 < n && (text[i + 1] == 120 || text[i + 1] == 88)) {
                        j += 1 // 1e-5
                    } else {
                        break
                    }
                }
                // "1.." 범위 끝의 점은 숫자가 아니다
                while j > i + 1, text[j - 1] == 46 { j -= 1 }
                token(.number, i, j)
                i = j
                continue
            }
            // 이름·키워드·타입
            if Self.isIdentStart(c) {
                var j = i + 1
                while j < n, Self.isIdent(text[j]) && !(spec.shellVariables && text[j] == 36) { j += 1 }
                let word = String(utf16CodeUnits: Array(text[i..<j]), count: j - i)
                if spec.keywords.contains(spec.caseInsensitive ? word.lowercased() : word) {
                    token(.keyword, i, j)
                } else if spec.capitalizedTypes, c >= 65, c <= 90, j - i > 1 || spec.language == .swift {
                    token(.type, i, j)
                }
                i = j
                continue
            }
            i += 1
        }
        return state
    }

    /// Rust: 'x' 'xy'(유니코드 한 글자) '\n' '\u{..}' 처럼 짧게 닫히면 문자
    private func isShortChar(_ text: UnsafeBufferPointer<UInt16>, _ i: Int) -> Bool {
        let n = text.count
        guard i + 2 < n else { return false }
        if text[i + 1] == Self.backslash {
            var j = i + 2
            while j < n, j < i + 12, text[j] != 39, text[j] != Self.newline { j += 1 }
            return j < n && text[j] == 39
        }
        if text[i + 2] == 39 { return true }
        // 대리 쌍(이모지 등)
        return i + 3 < n && text[i + 1] >= 0xD800 && text[i + 1] < 0xDC00 && text[i + 3] == 39
    }

    /// "- " 앞이 공백뿐인지(YAML 목록 항목의 키)
    private func lineOnlyDash(_ text: UnsafeBufferPointer<UInt16>, _ dash: Int) -> Bool {
        var j = dash - 1
        while j >= 0, Self.isSpace(text[j]) { j -= 1 }
        return j < 0 || text[j] == Self.newline
    }

    /// Markdown: 제목(#), 코드 블록(```), 인라인 코드(`…`), 인용(>), 목록 기호
    private func scanMarkdown(_ text: UnsafeBufferPointer<UInt16>, base: Int, state start: ScanState,
                              emit: (SyntaxToken) -> Void) -> ScanState {
        let n = text.count
        var i = 0
        var state = start
        func token(_ kind: SyntaxKind, _ from: Int, _ to: Int) {
            if to > from { emit(SyntaxToken(kind, base + from, to - from)) }
        }
        while i < n {
            // 줄 하나씩
            var end = i
            while end < n, text[end] != Self.newline { end += 1 }
            var j = i
            while j < end, Self.isSpace(text[j]) { j += 1 }
            let fence = j + 2 < end && text[j] == 96 && text[j + 1] == 96 && text[j + 2] == 96
            if state == .fence {
                token(.string, i, end)
                if fence { state = .normal }
            } else if fence {
                token(.string, i, end)
                state = .fence
            } else if j < end, text[j] == 35 {
                token(.heading, j, end)
            } else if j < end, text[j] == 62 {
                token(.comment, j, end)
            } else {
                if j + 1 < end, (text[j] == 45 || text[j] == 42 || text[j] == 43), text[j + 1] == 32 {
                    token(.keyword, j, j + 1)
                }
                // 인라인 코드
                var k = j
                while k < end {
                    if text[k] == 96 {
                        var close = k + 1
                        while close < end, text[close] != 96 { close += 1 }
                        if close < end {
                            token(.string, k, close + 1)
                            k = close + 1
                            continue
                        }
                    }
                    k += 1
                }
            }
            i = end + 1
        }
        return state
    }

    /// 시험·간단한 쓰임: 글 전체를 훑은 조각
    public func tokens(_ text: String, state: ScanState = .normal) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var result: [SyntaxToken] = []
        units.withUnsafeBufferPointer { buffer in
            scan(buffer, base: 0, state: state) { result.append($0) }
        }
        return result
    }

    /// 시험용: 끝 상태만
    public func endState(_ text: String, state: ScanState = .normal) -> ScanState {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { buffer in scan(buffer, base: 0, state: state) { _ in } }
    }
}
