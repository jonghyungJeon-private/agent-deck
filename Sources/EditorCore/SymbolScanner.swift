import Foundation

/// 선언 종류(⌘B·⌘O 목록의 표시). LSP 가 아니라 이름 단위 근사라 종류는 보이기·순서 정하기에만 쓴다.
public enum SymbolKind: UInt8, CaseIterable, Sendable {
    case `class`, interface, object, `enum`, record, annotation, `struct`, `protocol`, trait, typeAlias, module
    case function, method, constructor, property, field, constant, enumCase, variable

    /// 타입 종류(⌘O 에서 같은 점수면 먼저)
    public var isType: Bool { rawValue <= SymbolKind.module.rawValue }

    /// 목록 앞 작은 글자(IntelliJ 아이콘 대신)
    public var badge: String {
        switch self {
        case .class: return "C"
        case .interface: return "I"
        case .object: return "O"
        case .enum: return "E"
        case .record: return "R"
        case .annotation: return "@"
        case .struct: return "S"
        case .protocol: return "P"
        case .trait: return "T"
        case .typeAlias: return "A"
        case .module: return "N"
        case .function: return "f"
        case .method: return "m"
        case .constructor: return "c"
        case .property: return "p"
        case .field: return "f"
        case .constant: return "k"
        case .enumCase: return "e"
        case .variable: return "v"
        }
    }

    public var label: String {
        switch self {
        case .class: return "class"
        case .interface: return "interface"
        case .object: return "object"
        case .enum: return "enum"
        case .record: return "record"
        case .annotation: return "annotation"
        case .struct: return "struct"
        case .protocol: return "protocol"
        case .trait: return "trait"
        case .typeAlias: return "type"
        case .module: return "module"
        case .function: return "function"
        case .method: return "method"
        case .constructor: return "constructor"
        case .property: return "property"
        case .field: return "field"
        case .constant: return "constant"
        case .enumCase: return "enum case"
        case .variable: return "variable"
        }
    }
}

/// 찾은 선언 하나(줄은 0부터)
public struct SymbolDeclaration: Equatable, Sendable {
    public var name: String
    public var line: Int
    public var kind: SymbolKind
    /// 감싸는 타입 이름(멤버면)
    public var container: String?
    /// 지역 선언(includeLocals)이 보이는 줄 범위 — 감싸는 블록(함수 몸통·if 블록 등)의 여는 줄~닫는 줄. 멤버·최상위는 nil.
    public var scope: ClosedRange<Int>?

    public init(_ name: String, line: Int, kind: SymbolKind, container: String? = nil, scope: ClosedRange<Int>? = nil) {
        self.name = name
        self.line = line
        self.kind = kind
        self.container = container
        self.scope = scope
    }
}

public enum LocalScope {
    /// line 에서 보이는 가장 가까운 지역 선언(그 블록 안이고, 앞에 선언된 것). 없으면 nil(멤버·최상위로 찾는다).
    public static func nearest(_ declarations: [SymbolDeclaration], name: String, line: Int) -> SymbolDeclaration? {
        declarations.filter { d in
            guard d.name == name, let scope = d.scope else { return false }
            return d.line <= line && scope.contains(line)
        }.max { a, b in a.line != b.line ? a.line < b.line : (a.scope?.lowerBound ?? 0) < (b.scope?.lowerBound ?? 0) }
    }
}

/// 선언을 찾는 언어(나머지 언어는 선언 없음)
public enum SymbolLanguages {
    public static let supported: Set<SyntaxLanguage> = [.kotlin, .java, .typescript, .javascript, .swift, .python, .go, .rust]

    /// 색인할 소스 파일인지(확장자만 본다 — build.gradle·scala 같은 비슷한 것은 뺀다)
    public static func language(path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "gradle", "groovy", "scala": return nil
        default: break
        }
        if name.hasSuffix(".min.js") { return nil }
        guard let language = SyntaxLanguage.detect(path: path), supported.contains(language) else { return nil }
        return language
    }
}

// MARK: - 낱말 나누기

/// 선언 찾기용 낱말(주석·문자열은 건너뛴다). 바이트(UTF-8) 위치.
struct SymbolToken {
    enum Kind: UInt8 { case ident, punct, literal }
    var start: Int32
    var end: Int32
    var line: Int32
    /// 그 줄 첫 낱말의 들여쓰기(바이트, Python)
    var indent: Int32
    var kind: Kind
    /// 기호 글자(punct)
    var byte: UInt8
    /// 줄의 첫 낱말
    var first: Bool
}

/// 언어별 주석·문자열 규칙(글자 색 규칙 SyntaxSpec 에서 가져온다)
struct LexRules {
    var lineComments: [[UInt8]]
    var blockOpen: [UInt8]
    var blockClose: [UInt8]
    var nested: Bool
    var quotes: Set<UInt8>
    var multiline: [(open: [UInt8], close: [UInt8], escapes: Bool)]
    var shortCharQuotes: Bool
    /// `이름` 을 이름으로(Kotlin·Swift)
    var backtickIdent: Bool
    /// $ 를 이름 글자로(Java·JS 는 이름에 쓰고, Kotlin·Swift 는 문자열 틀 기호라 뺀다)
    var dollarIdent: Bool

    /// 언어마다 한 번만 만든다(파일마다 키워드 집합을 다시 만들지 않게)
    static let cache: [SyntaxLanguage: LexRules] = Dictionary(uniqueKeysWithValues: SymbolLanguages.supported.map { ($0, LexRules($0)) })

    static func of(_ language: SyntaxLanguage) -> LexRules { cache[language] ?? LexRules(language) }

    init(_ language: SyntaxLanguage) {
        let spec = language.spec
        lineComments = spec.lineComments.map { Array($0.utf8) }
        blockOpen = spec.blockComment.map { Array($0.open.utf8) } ?? []
        blockClose = spec.blockComment.map { Array($0.close.utf8) } ?? []
        nested = spec.nestedComments
        quotes = Set(spec.quotes.compactMap { $0 < 128 ? UInt8($0) : nil })
        // 긴 여는 기호부터(""" 를 " 보다 먼저)
        multiline = spec.multiline.map { (Array($0.open.utf8), Array($0.close.utf8), $0.escapes) }
            .sorted { $0.open.count > $1.open.count }
        shortCharQuotes = spec.shortCharQuotes
        backtickIdent = language == .kotlin || language == .swift
        dollarIdent = Identifier.allowsDollar(language)
    }
}

enum SymbolLexer {
    @inline(__always) static func isIdentStart(_ c: UInt8, dollar: Bool) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128 || (dollar && c == 36)
    }

    @inline(__always) static func isIdent(_ c: UInt8, dollar: Bool) -> Bool {
        isIdentStart(c, dollar: dollar) || (c >= 48 && c <= 57)
    }

    static func lex(_ s: UnsafeBufferPointer<UInt8>, rules: LexRules) -> [SymbolToken] {
        let n = s.count
        var tokens: [SymbolToken] = []
        tokens.reserveCapacity(n / 5)
        var i = 0
        var line: Int32 = 0
        var lineStart = 0
        var lineFirst = true
        var lineIndent: Int32 = 0

        @inline(__always) func matches(_ pattern: [UInt8], _ at: Int) -> Bool {
            guard !pattern.isEmpty, at + pattern.count <= n else { return false }
            for k in 0..<pattern.count where s[at + k] != pattern[k] { return false }
            return true
        }
        func emit(_ kind: SymbolToken.Kind, _ from: Int, _ to: Int, _ byte: UInt8 = 0) {
            if lineFirst { lineIndent = Int32(from - lineStart) }
            tokens.append(SymbolToken(start: Int32(from), end: Int32(to), line: line, indent: lineIndent, kind: kind,
                                      byte: byte, first: lineFirst))
            lineFirst = false
        }
        @inline(__always) func newline(_ at: Int) {
            line += 1
            lineStart = at + 1
            lineFirst = true
        }

        while i < n {
            let c = s[i]
            if c == 10 { newline(i); i += 1; continue }
            if c == 32 || c == 9 || c == 13 || c == 12 { i += 1; continue }
            // 한 줄 주석
            if c == 47 || c == 35 || c == 45, rules.lineComments.contains(where: { matches($0, i) }) {
                while i < n, s[i] != 10 { i += 1 }
                continue
            }
            // 블록 주석
            if matches(rules.blockOpen, i) {
                var depth = 1
                i += rules.blockOpen.count
                while i < n {
                    if matches(rules.blockClose, i) {
                        i += rules.blockClose.count
                        depth -= 1
                        if depth == 0 { break }
                    } else if rules.nested, matches(rules.blockOpen, i) {
                        i += rules.blockOpen.count
                        depth += 1
                    } else {
                        if s[i] == 10 { newline(i) }
                        i += 1
                    }
                }
                continue
            }
            // 여러 줄 문자열
            if let m = rules.multiline.first(where: { matches($0.open, i) }) {
                let from = i
                emit(.literal, from, from)
                i += m.open.count
                while i < n {
                    if m.escapes, s[i] == 92 { if i + 1 < n, s[i + 1] == 10 { newline(i + 1) }; i += 2; continue }
                    if matches(m.close, i) { i += m.close.count; break }
                    if s[i] == 10 { newline(i) }
                    i += 1
                }
                tokens[tokens.count - 1].end = Int32(min(i, n))
                continue
            }
            // 한 줄 문자열(줄 끝에서 끝난다)
            if rules.quotes.contains(c) {
                if rules.shortCharQuotes, c == 39 {
                    // Rust: 'a' 'x' '\n' 만 문자, 'a 는 수명(기호로 둔다)
                    let isChar = (i + 2 < n && s[i + 2] == 39) || (i + 1 < n && s[i + 1] == 92)
                    if !isChar { emit(.punct, i, i + 1, c); i += 1; continue }
                }
                let from = i
                i += 1
                while i < n, s[i] != 10 {
                    if s[i] == 92 { i += 2; continue }
                    if s[i] == c { i += 1; break }
                    i += 1
                }
                emit(.literal, from, min(i, n))
                continue
            }
            if c == 96, rules.backtickIdent {
                var j = i + 1
                while j < n, s[j] != 96, s[j] != 10 { j += 1 }
                if j < n, s[j] == 96, j > i + 1 {
                    emit(.ident, i + 1, j)
                    i = j + 1
                } else {
                    emit(.punct, i, i + 1, c)
                    i += 1
                }
                continue
            }
            if isIdentStart(c, dollar: rules.dollarIdent) {
                let from = i
                i += 1
                while i < n, isIdent(s[i], dollar: rules.dollarIdent) { i += 1 }
                emit(.ident, from, i)
                continue
            }
            if c >= 48 && c <= 57 {
                let from = i
                i += 1
                while i < n, isIdent(s[i], dollar: false) || (s[i] == 46 && i + 1 < n && s[i + 1] >= 48 && s[i + 1] <= 57) { i += 1 }
                emit(.literal, from, i)
                continue
            }
            emit(.punct, i, i + 1, c)
            i += 1
        }
        return tokens
    }
}

// MARK: - 선언 찾기

/// 언어별 손으로 쓴 가벼운 선언 찾기(정규식·LSP 없음). 주석·문자열은 건너뛰고, 중괄호로 범위를 따라가
/// 타입 몸통의 멤버만 멤버로 본다(함수 안 지역 변수는 includeLocals 일 때만).
public enum SymbolScanner {
    public static func scan(_ text: String, language: SyntaxLanguage, includeLocals: Bool = false) -> [SymbolDeclaration] {
        var copy = text
        return copy.withUTF8 { scan($0, language: language, includeLocals: includeLocals) }
    }

    public static func scan(_ bytes: UnsafeBufferPointer<UInt8>, language: SyntaxLanguage,
                            includeLocals: Bool = false) -> [SymbolDeclaration] {
        guard SymbolLanguages.supported.contains(language) else { return [] }
        let tokens = SymbolLexer.lex(bytes, rules: LexRules.of(language))
        var parser = DeclarationParser(bytes: bytes, tokens: tokens, language: language, includeLocals: includeLocals)
        if language == .python {
            parser.runPython()
        } else {
            parser.run()
        }
        return parser.output
    }
}

private struct DeclarationParser {
    enum ScopeKind { case type, function, block }

    struct Scope {
        var kind: ScopeKind
        var name: String?
        /// 멤버를 "타입 이름(" 꼴로 찾는 몸통(Java·TS 클래스, Go struct·interface, Rust struct)
        var members = false
        var isEnum = false
        /// enum 항목 부분(첫 ; 전)
        var entriesOpen = false
        var typeKind: SymbolKind?
        var savedParen = 0
        /// 여는 { 의 줄, 이 블록에 선언된 지역(output 위치) — 닫힐 때 보이는 범위를 채운다
        var openLine = 0
        var locals: [Int] = []
    }

    let s: UnsafeBufferPointer<UInt8>
    let tokens: [SymbolToken]
    let language: SyntaxLanguage
    let includeLocals: Bool
    var output: [SymbolDeclaration] = []
    var stack: [Scope] = []
    var pending: Scope?
    var paren = 0
    /// 이미 선언으로 읽은 낱말까지(@주석 줄 다음 줄의 키워드를 두 번 읽지 않게)
    var skipUntil = -1

    init(bytes: UnsafeBufferPointer<UInt8>, tokens: [SymbolToken], language: SyntaxLanguage, includeLocals: Bool) {
        s = bytes
        self.tokens = tokens
        self.language = language
        self.includeLocals = includeLocals
    }

    // MARK: 낱말 도우미

    func word(_ i: Int) -> String {
        guard i < tokens.count, tokens[i].kind == .ident else { return "" }
        let t = tokens[i]
        return String(decoding: UnsafeBufferPointer(rebasing: s[Int(t.start)..<Int(t.end)]), as: UTF8.self)
    }

    /// 낱말이 이 글자인지(이름 비교에 문자열을 만들지 않게)
    func isWord(_ i: Int, _ text: StaticString) -> Bool {
        guard i < tokens.count, tokens[i].kind == .ident else { return false }
        let t = tokens[i]
        let count = Int(t.end - t.start)
        guard count == text.utf8CodeUnitCount else { return false }
        let p = text.utf8Start
        for k in 0..<count where s[Int(t.start) + k] != p[k] { return false }
        return true
    }

    func isWord(_ i: Int, in set: Set<String>) -> Bool {
        guard i < tokens.count, tokens[i].kind == .ident else { return false }
        return set.contains(word(i))
    }

    func isPunct(_ i: Int, _ c: UInt8) -> Bool {
        i < tokens.count && i >= 0 && tokens[i].kind == .punct && tokens[i].byte == c
    }

    func isIdent(_ i: Int) -> Bool { i < tokens.count && tokens[i].kind == .ident }

    /// 두 기호가 붙어 있는지(-> => :: 등)
    func adjacent(_ i: Int) -> Bool { i + 1 < tokens.count && tokens[i].end == tokens[i + 1].start }

    var top: Scope? { stack.last }
    var inType: Bool { top?.kind == .type }
    var atTopLevel: Bool { stack.isEmpty }
    /// 지역(함수·블록) 안
    var inLocal: Bool { guard let top else { return false }; return top.kind != .type }
    var containerName: String? { inType ? top?.name : nil }

    mutating func add(_ i: Int, _ kind: SymbolKind, container: String? = nil) {
        guard isIdent(i) else { return }
        let name = word(i)
        guard !name.isEmpty else { return }
        output.append(SymbolDeclaration(name, line: Int(tokens[i].line), kind: kind, container: container ?? containerName))
        if inLocal { stack[stack.count - 1].locals.append(output.count - 1) }
    }

    /// 닫힌(또는 파일 끝까지 열린) 블록의 지역 선언에 보이는 범위를 채운다
    mutating func closeLocals(_ scope: Scope, endLine: Int) {
        for index in scope.locals { output[index].scope = scope.openLine...max(endLine, scope.openLine) }
    }

    /// 짝 맞는 닫는 기호 다음 위치(못 찾으면 limit 까지)
    func skipBalanced(_ i: Int, _ open: UInt8, _ close: UInt8, limit: Int = 2_000) -> Int {
        guard isPunct(i, open) else { return i }
        var depth = 0
        var j = i
        let end = min(tokens.count, i + limit)
        while j < end {
            if isPunct(j, open) { depth += 1 } else if isPunct(j, close) {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return end
    }

    /// <…> 건너뛰기(-> 의 > 는 세지 않는다). { ; 를 만나면 제네릭이 아니므로 그대로 둔다.
    func skipGenerics(_ i: Int) -> Int {
        guard isPunct(i, 60) else { return i }
        var depth = 0
        var j = i
        let end = min(tokens.count, i + 200)
        while j < end {
            let t = tokens[j]
            if t.kind == .punct {
                switch t.byte {
                case 60: depth += 1
                case 62:
                    if !(j > 0 && isPunct(j - 1, 45) && tokens[j - 1].end == t.start) && !(j > 0 && isPunct(j - 1, 61) && tokens[j - 1].end == t.start) {
                        depth -= 1
                        if depth == 0 { return j + 1 }
                    }
                case 123, 125, 59: return i
                default: break
                }
            }
            j += 1
        }
        return i
    }

    /// @이름(.이름)*(:이름)*(…) 건너뛰기(Java @interface 는 건너뛰지 않는다)
    func skipAnnotation(_ i: Int) -> Int {
        guard isPunct(i, 64), isIdent(i + 1), !isWord(i + 1, "interface") else { return i }
        var j = i + 2
        while (isPunct(j, 46) || isPunct(j, 58)) && isIdent(j + 1) { j += 2 }
        if isPunct(j, 40), tokens[j].line == tokens[j - 1].line || adjacentTokens(j - 1, j) { j = skipBalanced(j, 40, 41) }
        return j
    }

    func adjacentTokens(_ a: Int, _ b: Int) -> Bool { tokens[a].end == tokens[b].start }

    func statementStart(_ i: Int) -> Bool {
        let t = tokens[i]
        if t.first { return true }
        guard i > 0, tokens[i - 1].kind == .punct else { return false }
        let b = tokens[i - 1].byte
        return b == 59 || b == 123 || b == 125
    }

    // MARK: 중괄호 언어

    mutating func run() {
        var i = 0
        let count = tokens.count
        while i < count {
            let t = tokens[i]
            // @주석·#[속성] 으로 시작하는 선언
            if t.kind == .punct, t.byte == 64 || t.byte == 35, paren == 0, i > skipUntil, statementStart(i) {
                declaration(i)
            }
            if t.kind == .punct {
                switch t.byte {
                case 40, 91: paren += 1
                case 41, 93: paren = max(0, paren - 1)
                case 123:
                    // 괄호 안의 { (생성자·함수 기본값 람다, Java @Foo({…}) 배열)는 선언 몸통이 아니다 — 기다리는 범위를 쓰지 않는다
                    var scope = paren == 0 ? (pending ?? Scope(kind: .block)) : Scope(kind: .block)
                    scope.savedParen = paren
                    scope.openLine = Int(t.line)
                    if scope.isEnum { scope.entriesOpen = true }
                    stack.append(scope)
                    if paren == 0 { pending = nil }
                    paren = 0
                case 125:
                    if let last = stack.popLast() {
                        paren = last.savedParen
                        closeLocals(last, endLine: Int(t.line))
                        if last.savedParen == 0 { pending = nil }
                    }
                case 59:
                    if paren == 0 {
                        pending = nil
                        if top?.entriesOpen == true { stack[stack.count - 1].entriesOpen = false }
                    }
                default: break
                }
                i += 1
                continue
            }
            if paren == 0, top?.entriesOpen == true, t.kind == .ident, i > 0, isPunct(i - 1, 123) || isPunct(i - 1, 44) {
                enumEntry(i)
            } else if paren == 0, i > skipUntil, statementStart(i) {
                declaration(i)
            }
            i += 1
        }
        // 닫히지 않은 블록(편집 중)은 파일 끝까지
        let last = Int(tokens.last?.line ?? 0)
        while let open = stack.popLast() { closeLocals(open, endLine: last) }
    }

    mutating func enumEntry(_ i: Int) {
        // 다음이 , ( ; } { = 이거나 줄이 바뀌면 항목
        let next = i + 1
        let ok = next >= tokens.count || tokens[next].first || isPunct(next, 44) || isPunct(next, 40) || isPunct(next, 59)
            || isPunct(next, 125) || isPunct(next, 123) || isPunct(next, 61)
        guard ok else {
            if statementStart(i) { declaration(i) }
            return
        }
        // Kotlin·Swift 의 enum 몸통 안 선언 키워드는 항목이 아니다
        if language == .swift, isWord(i, "case") { declaration(i); return }
        add(i, .enumCase)
    }

    mutating func declaration(_ i: Int) {
        switch language {
        case .kotlin: kotlin(i)
        case .java: java(i)
        case .typescript, .javascript: typescript(i)
        case .swift: swift(i)
        case .go: go(i)
        case .rust: rust(i)
        default: break
        }
    }

    // MARK: Kotlin

    static let kotlinModifiers: Set<String> = [
        "public", "private", "protected", "internal", "open", "abstract", "final", "sealed", "data", "enum", "annotation",
        "inner", "value", "inline", "noinline", "crossinline", "override", "suspend", "tailrec", "operator", "infix",
        "external", "lateinit", "const", "expect", "actual", "companion", "vararg", "reified",
    ]

    /// 꾸밈말·주석(@…)을 건너뛰고, 본 꾸밈말을 돌려준다
    mutating func skipModifiers(_ i: Int, _ modifiers: Set<String>) -> (Int, Set<String>) {
        let result = modifierEnd(i, modifiers)
        skipUntil = max(skipUntil, result.0)
        return result
    }

    func modifierEnd(_ i: Int, _ modifiers: Set<String>) -> (Int, Set<String>) {
        var j = i
        var seen: Set<String> = []
        var guardCount = 0
        while j < tokens.count, guardCount < 40 {
            guardCount += 1
            if isPunct(j, 64) {
                let next = skipAnnotation(j)
                if next == j { break }
                j = next
                continue
            }
            guard isIdent(j) else { break }
            let w = word(j)
            guard modifiers.contains(w) else { break }
            // 꾸밈말 다음이 이름이 아니면(예: Kotlin `value = 1`) 꾸밈말이 아니다. Swift private(set) 은 괄호까지.
            if isPunct(j + 1, 40), language == .swift {
                seen.insert(w)
                j = skipBalanced(j + 1, 40, 41)
                continue
            }
            guard isIdent(j + 1) || isPunct(j + 1, 64) || isPunct(j + 1, 60) else { break }
            seen.insert(w)
            j += 1
        }
        return (j, seen)
    }

    mutating func kotlin(_ i: Int) {
        let (j, mods) = skipModifiers(i, Self.kotlinModifiers)
        guard isIdent(j) else { return }
        if isWord(j, "class") || isWord(j, "interface") || (isWord(j, "fun") && isWord(j + 1, "interface")) {
            let k = isWord(j, "fun") ? j + 1 : j
            var kind: SymbolKind = isWord(k, "interface") ? .interface : .class
            if mods.contains("enum") { kind = .enum }
            if mods.contains("annotation") { kind = .annotation }
            kotlinType(k, kind: kind)
        } else if isWord(j, "object") {
            if isIdent(j + 1) {
                kotlinType(j, kind: .object)
            } else {
                // companion object(이름 없음): 멤버는 바깥 타입 소속으로
                pending = Scope(kind: .type, name: containerName ?? top?.name)
            }
        } else if isWord(j, "fun") {
            var k = skipGenerics(j + 1)
            var name = -1
            var steps = 0
            while k < tokens.count, steps < 40, !isPunct(k, 40) {
                if tokens[k].first && k > j + 1 { break }
                if isPunct(k, 60) { let next = skipGenerics(k); if next == k { break }; k = next; continue }
                if isPunct(k, 123) || isPunct(k, 61) { break }
                if isIdent(k) { name = k }
                k += 1
                steps += 1
            }
            if name >= 0, isPunct(k, 40) {
                if inLocal {
                    if includeLocals { add(name, .function) }
                } else {
                    add(name, inType ? .method : .function)
                }
            }
            pending = Scope(kind: .function)
        } else if isWord(j, "val") || isWord(j, "var") {
            pending = nil
            guard let name = propertyName(j + 1) else { return }
            if inLocal {
                if includeLocals { add(name, .variable) }
            } else {
                add(name, mods.contains("const") ? .constant : .property)
            }
        } else if isWord(j, "typealias") {
            add(j + 1, .typeAlias)
            pending = nil
        } else if isWord(j, "constructor"), inType, let name = top?.name {
            output.append(SymbolDeclaration(name, line: Int(tokens[j].line), kind: .constructor, container: name))
            pending = Scope(kind: .function)
        } else if isWord(j, "init") {
            pending = Scope(kind: .function)
        }
    }

    /// val·var 다음 이름: 받는 쪽 타입(`val Foo.bar`)·제네릭을 지나 : = by 앞의 마지막 이름
    func propertyName(_ start: Int) -> Int? {
        if isPunct(start, 40) { return nil } // (a, b) 나눠 받기
        var k = skipGenerics(start)
        var name: Int?
        var steps = 0
        while k < tokens.count, steps < 20 {
            if k > start, tokens[k].first { break }
            if isIdent(k) {
                if isWord(k, "by") { break }
                name = k
            } else if isPunct(k, 46) || isPunct(k, 63) {
                // . ? 는 받는 쪽 타입
            } else if isPunct(k, 60) {
                let next = skipGenerics(k)
                if next == k { break }
                k = next
                continue
            } else {
                break
            }
            k += 1
            steps += 1
        }
        return name
    }

    mutating func kotlinType(_ k: Int, kind: SymbolKind) {
        guard isIdent(k + 1) else { return }
        let nameIndex = k + 1
        let name = word(nameIndex)
        if inLocal {
            if includeLocals { add(nameIndex, kind) }
        } else {
            add(nameIndex, kind)
        }
        // 주 생성자의 val·var = 속성
        var j = skipGenerics(nameIndex + 1)
        var steps = 0
        while j < tokens.count, steps < 12, !isPunct(j, 40) {
            if isPunct(j, 64) { let next = skipAnnotation(j); if next == j { break }; j = next; steps += 1; continue }
            guard isIdent(j), isWord(j, in: Self.kotlinModifiers) || isWord(j, "constructor") else { break }
            j += 1
            steps += 1
        }
        if isPunct(j, 40) {
            let end = skipBalanced(j, 40, 41)
            var depth = 0
            var p = j
            while p < end {
                if isPunct(p, 40) || isPunct(p, 91) || isPunct(p, 123) { depth += 1 }
                if isPunct(p, 41) || isPunct(p, 93) || isPunct(p, 125) { depth -= 1 }
                if depth == 1, isWord(p, "val") || isWord(p, "var"), isIdent(p + 1) {
                    output.append(SymbolDeclaration(word(p + 1), line: Int(tokens[p + 1].line), kind: .property, container: name))
                }
                p += 1
            }
        }
        pending = Scope(kind: .type, name: name, isEnum: kind == .enum, typeKind: kind)
    }

    // MARK: Java

    static let javaModifiers: Set<String> = [
        "public", "private", "protected", "static", "final", "abstract", "synchronized", "native", "transient", "volatile",
        "strictfp", "default", "sealed", "non",
    ]
    static let javaNotTypes: Set<String> = [
        "return", "throw", "new", "if", "else", "for", "while", "do", "switch", "case", "try", "catch", "finally", "break",
        "continue", "assert", "package", "import", "this", "super", "throws", "extends", "implements", "permits", "yield",
    ]

    mutating func java(_ i: Int) {
        var (j, mods) = skipModifiers(i, Self.javaModifiers)
        // non-sealed
        if isPunct(j, 45), isWord(j + 1, "sealed") { j += 2; mods.insert("sealed") }
        if isPunct(j, 64), isWord(j + 1, "interface") {
            javaType(j + 1, kind: .annotation)
            return
        }
        guard isIdent(j) || isPunct(j, 60) else { return }
        if isWord(j, "class") { javaType(j, kind: .class); return }
        if isWord(j, "interface") { javaType(j, kind: .interface); return }
        if isWord(j, "enum") { javaType(j, kind: .enum); return }
        if isWord(j, "record"), isIdent(j + 1) { javaType(j, kind: .record); return }
        guard inType, top?.members == true else { return }
        // 멤버: [<T>] 타입 이름 ( | = | ; | ,
        var k = skipGenerics(j)
        guard isIdent(k), !isWord(k, in: Self.javaNotTypes) else { return }
        if let typeName = top?.name, word(k) == typeName, isPunct(k + 1, 40) {
            add(k, .constructor, container: typeName)
            pending = Scope(kind: .function)
            return
        }
        // 타입
        k += 1
        while true {
            if isPunct(k, 46), isIdent(k + 1) { k += 2; continue }
            if isPunct(k, 60) { let next = skipGenerics(k); if next == k { return }; k = next; continue }
            if isPunct(k, 91), isPunct(k + 1, 93) { k += 2; continue }
            if isPunct(k, 46), isPunct(k + 1, 46), isPunct(k + 2, 46) { k += 3; continue }
            if isPunct(k, 64) { let next = skipAnnotation(k); if next == k { return }; k = next; continue }
            break
        }
        guard isIdent(k) else { return }
        if isPunct(k + 1, 40) {
            add(k, .method)
            pending = Scope(kind: .function)
        } else if isPunct(k + 1, 61) || isPunct(k + 1, 59) || isPunct(k + 1, 44) || isPunct(k + 1, 91) {
            let name = word(k)
            let constant = mods.contains("static") && mods.contains("final") && name == name.uppercased()
            add(k, constant ? .constant : .field)
        }
    }

    mutating func javaType(_ k: Int, kind: SymbolKind) {
        guard isIdent(k + 1) else { return }
        let name = word(k + 1)
        add(k + 1, kind)
        if kind == .record {
            // 레코드 구성 요소 = 필드(같은 이름 접근 메서드)
            let open = skipGenerics(k + 2)
            if isPunct(open, 40) {
                let end = skipBalanced(open, 40, 41)
                var depth = 0
                var p = open
                while p < end {
                    if isPunct(p, 40) || isPunct(p, 60) { depth += 1 }
                    if isPunct(p, 41) || isPunct(p, 62) { depth -= 1 }
                    if isIdent(p), depth == 1, isPunct(p + 1, 44) || isPunct(p + 1, 41) {
                        output.append(SymbolDeclaration(word(p), line: Int(tokens[p].line), kind: .field, container: name))
                    }
                    p += 1
                }
            }
        }
        pending = Scope(kind: .type, name: name, members: true, isEnum: kind == .enum, typeKind: kind)
    }

    // MARK: TypeScript·JavaScript

    static let tsModifiers: Set<String> = [
        "export", "default", "declare", "abstract", "async", "public", "private", "protected", "static", "readonly",
        "override", "accessor",
    ]
    static let tsNotMembers: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "return", "throw", "try", "catch", "finally", "new", "delete",
        "typeof", "await", "yield", "break", "continue", "import", "export", "this", "super", "void", "in", "of",
    ]

    mutating func typescript(_ i: Int) {
        var (j, _) = skipModifiers(i, Self.tsModifiers)
        if isWord(j, "const"), isWord(j + 1, "enum") { j += 1 }
        guard isIdent(j) else {
            if isPunct(j, 35), isIdent(j + 1), inType, top?.members == true { tsMember(j + 1) }
            return
        }
        if isWord(j, "class") {
            if isIdent(j + 1), !isWord(j + 1, "extends"), !isWord(j + 1, "implements") {
                add(j + 1, .class)
                pending = Scope(kind: .type, name: word(j + 1), members: true, typeKind: .class)
            } else {
                pending = Scope(kind: .type, name: nil, members: true)
            }
        } else if isWord(j, "interface"), isIdent(j + 1) {
            add(j + 1, .interface)
            pending = Scope(kind: .type, name: word(j + 1), members: true, typeKind: .interface)
        } else if isWord(j, "enum"), isIdent(j + 1) {
            add(j + 1, .enum)
            pending = Scope(kind: .type, name: word(j + 1), isEnum: true, typeKind: .enum)
        } else if (isWord(j, "namespace") || isWord(j, "module")), isIdent(j + 1) {
            add(j + 1, .module)
            pending = Scope(kind: .type, name: word(j + 1))
        } else if isWord(j, "type"), isIdent(j + 1), isPunct(j + 2, 61) || isPunct(j + 2, 60) {
            add(j + 1, .typeAlias)
            pending = nil
        } else if isWord(j, "function") {
            let k = isPunct(j + 1, 42) ? j + 2 : j + 1
            if isIdent(k) {
                if inLocal { if includeLocals { add(k, .function) } } else { add(k, .function) }
            }
            pending = Scope(kind: .function)
        } else if isWord(j, "const") || isWord(j, "let") || isWord(j, "var") {
            pending = nil
            guard isIdent(j + 1) else { return }
            if inType && top?.members == true { return }
            let kind: SymbolKind = isArrowFunction(after: j + 2) ? .function : (isWord(j, "const") ? .constant : .variable)
            if inLocal {
                if includeLocals { add(j + 1, kind == .constant ? .variable : kind) }
            } else {
                add(j + 1, kind)
            }
        } else if inType, top?.members == true {
            tsMember(j)
        }
    }

    /// = 다음이 함수인지(async·function·( … ) => ·이름 =>)
    func isArrowFunction(after start: Int) -> Bool {
        var k = start
        // 타입 표기 : T 를 지나 = 를 찾는다(같은 줄)
        var steps = 0
        while k < tokens.count, steps < 30, !isPunct(k, 61) {
            if tokens[k].first || isPunct(k, 59) { return false }
            k += 1
            steps += 1
        }
        guard isPunct(k, 61) else { return false }
        let v = k + 1
        if isWord(v, "async") || isWord(v, "function") { return true }
        // => 를 같은 문장 앞쪽에서 찾는다
        var p = v
        steps = 0
        while p + 1 < tokens.count, steps < 60 {
            if isPunct(p, 59) || isPunct(p, 123) { break }
            if isPunct(p, 61), isPunct(p + 1, 62), adjacent(p) { return true }
            p += 1
            steps += 1
        }
        return false
    }

    mutating func tsMember(_ j: Int) {
        var k = j
        // get·set 접근자
        if (isWord(k, "get") || isWord(k, "set")), isIdent(k + 1) { k += 1 }
        guard isIdent(k), !isWord(k, in: Self.tsNotMembers) else { return }
        if isWord(k, "constructor"), isPunct(k + 1, 40) {
            if let name = top?.name { output.append(SymbolDeclaration(name, line: Int(tokens[k].line), kind: .constructor, container: name)) }
            pending = Scope(kind: .function)
            return
        }
        var n = k + 1
        if isPunct(n, 63) || isPunct(n, 33) { n += 1 }
        if isPunct(n, 40) || isPunct(n, 60) {
            add(k, .method)
            pending = Scope(kind: .function)
        } else if isPunct(n, 61) || isPunct(n, 58) || isPunct(n, 59) || n >= tokens.count || tokens[n].first || isPunct(n, 125) {
            add(k, .property)
        }
    }

    // MARK: Swift

    static let swiftModifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "final", "static", "override", "mutating", "nonmutating",
        "convenience", "required", "lazy", "weak", "unowned", "dynamic", "indirect", "nonisolated", "optional", "prefix",
        "postfix", "infix", "package", "distributed",
    ]

    mutating func swift(_ i: Int) {
        var (j, _) = skipModifiers(i, Self.swiftModifiers)
        // class func / class var 의 class 는 꾸밈말
        if isWord(j, "class"), isWord(j + 1, "func") || isWord(j + 1, "var") || isWord(j + 1, "let")
            || isWord(j + 1, in: Self.swiftModifiers) {
            (j, _) = skipModifiers(j + 1, Self.swiftModifiers)
        }
        guard isIdent(j) else { return }
        let types: [(StaticString, SymbolKind)] = [("class", .class), ("struct", .struct), ("enum", .enum),
                                                    ("protocol", .protocol), ("actor", .class)]
        for (keyword, kind) in types where isWord(j, keyword) {
            guard isIdent(j + 1) else { return }
            if inLocal { if includeLocals { add(j + 1, kind) } } else { add(j + 1, kind) }
            pending = Scope(kind: .type, name: word(j + 1), typeKind: kind)
            return
        }
        if isWord(j, "extension") {
            // 확장한 타입의 마지막 이름(Foo.Bar → Bar)
            var k = j + 1
            var name: String?
            while isIdent(k) { name = word(k); if isPunct(k + 1, 46) { k += 2 } else { break } }
            pending = Scope(kind: .type, name: name)
        } else if isWord(j, "func") {
            if isIdent(j + 1) {
                if inLocal { if includeLocals { add(j + 1, .function) } } else { add(j + 1, inType ? .method : .function) }
            }
            pending = Scope(kind: .function)
        } else if isWord(j, "init") {
            if inType, let name = top?.name {
                output.append(SymbolDeclaration(name, line: Int(tokens[j].line), kind: .constructor, container: name))
            }
            pending = Scope(kind: .function)
        } else if isWord(j, "deinit") || isWord(j, "subscript") {
            pending = Scope(kind: .function)
        } else if isWord(j, "var") || isWord(j, "let") {
            pending = nil
            guard isIdent(j + 1) else { return }
            if inLocal { if includeLocals { add(j + 1, .variable) } } else { add(j + 1, .property) }
        } else if isWord(j, "typealias") || isWord(j, "associatedtype") {
            add(j + 1, .typeAlias)
            pending = nil
        } else if isWord(j, "case"), inType, top?.typeKind == .enum {
            // case a, b(Int), c = 1
            let line = tokens[j].line
            var k = j + 1
            var depth = 0
            var expectName = true
            while k < tokens.count, tokens[k].line == line {
                if isPunct(k, 40) { depth += 1 } else if isPunct(k, 41) { depth -= 1 }
                if depth == 0, expectName, isIdent(k) { add(k, .enumCase); expectName = false }
                if depth == 0, isPunct(k, 44) { expectName = true }
                k += 1
            }
        }
    }

    // MARK: Go

    mutating func go(_ i: Int) {
        let j = i
        if isWord(j, "func") {
            var k = j + 1
            var receiver: String?
            if isPunct(k, 40) {
                let end = skipBalanced(k, 40, 41)
                for p in stride(from: end - 1, to: k, by: -1) where isIdent(p) {
                    // 받는 쪽 타입 = 괄호 안에서 제네릭 대괄호 밖의 마지막 이름
                    if !isPunct(p - 1, 91) && !isPunct(p - 1, 44) || isPunct(p - 1, 42) { receiver = word(p); break }
                }
                k = end
            }
            if isIdent(k) {
                if inLocal { if includeLocals { add(k, .function) } } else {
                    add(k, receiver == nil ? .function : .method, container: receiver)
                }
            }
            pending = Scope(kind: .function)
        } else if isWord(j, "type") {
            if isPunct(j + 1, 40) {
                goGroup(j + 1) { this, p in this.goTypeSpec(p) }
            } else if isIdent(j + 1) {
                goTypeSpec(j + 1)
            }
        } else if isWord(j, "var") || isWord(j, "const") {
            let kind: SymbolKind = isWord(j, "const") ? .constant : .variable
            if inLocal && !includeLocals { return }
            if isPunct(j + 1, 40) {
                goGroup(j + 1) { this, p in this.goNames(p, kind) }
            } else {
                goNames(j + 1, kind)
            }
        } else if inType, top?.members == true, isIdent(j) {
            // struct 필드(이름 다음이 타입) · interface 메서드(이름 다음이 ()
            if isPunct(j + 1, 40) {
                add(j, .method)
            } else if top?.typeKind == .struct, isIdent(j + 1) || isPunct(j + 1, 42) || isPunct(j + 1, 91) || isPunct(j + 1, 44) {
                goNames(j, .field)
            }
        }
    }

    /// ( … ) 묶음의 줄 첫 이름마다
    mutating func goGroup(_ open: Int, _ body: (inout DeclarationParser, Int) -> Void) {
        let end = skipBalanced(open, 40, 41)
        var depth = 0
        var p = open
        while p < end {
            if isPunct(p, 40) || isPunct(p, 123) || isPunct(p, 91) { depth += 1 }
            if isPunct(p, 41) || isPunct(p, 125) || isPunct(p, 93) { depth -= 1 }
            if depth == 1, isIdent(p), tokens[p].first || isPunct(p - 1, 40) || isPunct(p - 1, 59) { body(&self, p) }
            p += 1
        }
    }

    mutating func goTypeSpec(_ p: Int) {
        var k = p + 1
        if isPunct(k, 91) { k = skipBalanced(k, 91, 93) } // 제네릭 [T any]
        if isPunct(k, 61) { k += 1 }
        let kind: SymbolKind = isWord(k, "struct") ? .struct : isWord(k, "interface") ? .interface : .typeAlias
        if inLocal { if includeLocals { add(p, kind) } } else { add(p, kind) }
        if kind != .typeAlias { pending = Scope(kind: .type, name: word(p), members: true, typeKind: kind) }
    }

    mutating func goNames(_ p: Int, _ kind: SymbolKind) {
        var k = p
        while isIdent(k) {
            add(k, inLocal ? .variable : kind)
            guard isPunct(k + 1, 44) else { break }
            k += 2
        }
    }

    // MARK: Rust

    static let rustModifiers: Set<String> = ["pub", "async", "unsafe", "extern", "default"]

    mutating func rust(_ i: Int) {
        var j = i
        // #[…] 속성
        while isPunct(j, 35), isPunct(j + 1, 91) || (isPunct(j + 1, 33) && isPunct(j + 2, 91)) {
            j = skipBalanced(isPunct(j + 1, 33) ? j + 2 : j + 1, 91, 93)
        }
        var steps = 0
        while steps < 8 {
            steps += 1
            if isWord(j, in: Self.rustModifiers) {
                j += 1
                if isPunct(j, 40) { j = skipBalanced(j, 40, 41) } // pub(crate)
                if j < tokens.count, tokens[j].kind == .literal { j += 1 } // extern "C"
                continue
            }
            if isWord(j, "const"), isWord(j + 1, "fn") || isWord(j + 1, "unsafe") || isWord(j + 1, "async") { j += 1; continue }
            break
        }
        skipUntil = max(skipUntil, j)
        guard isIdent(j) else { return }
        if isWord(j, "fn") {
            if isIdent(j + 1) {
                if inLocal { if includeLocals { add(j + 1, .function) } } else { add(j + 1, inType ? .method : .function) }
            }
            pending = Scope(kind: .function)
        } else if isWord(j, "struct") || isWord(j, "union") {
            guard isIdent(j + 1) else { return }
            add(j + 1, .struct)
            pending = Scope(kind: .type, name: word(j + 1), members: true, typeKind: .struct)
        } else if isWord(j, "enum") {
            guard isIdent(j + 1) else { return }
            add(j + 1, .enum)
            pending = Scope(kind: .type, name: word(j + 1), isEnum: true, typeKind: .enum)
        } else if isWord(j, "trait") {
            guard isIdent(j + 1) else { return }
            add(j + 1, .trait)
            pending = Scope(kind: .type, name: word(j + 1), typeKind: .trait)
        } else if isWord(j, "type") {
            add(j + 1, .typeAlias)
        } else if isWord(j, "mod") {
            add(j + 1, .module)
            pending = Scope(kind: .type, name: word(j + 1))
        } else if isWord(j, "const") || isWord(j, "static") {
            let k = isWord(j + 1, "mut") ? j + 2 : j + 1
            if inLocal { if includeLocals { add(k, .variable) } } else { add(k, .constant) }
        } else if isWord(j, "impl") {
            // impl<T> Trait for Foo<T> → Foo, impl Foo → Foo
            var k = skipGenerics(j + 1)
            var name: String?
            var steps = 0
            while k < tokens.count, steps < 30, !isPunct(k, 123) {
                if isWord(k, "for") { name = nil } else if isWord(k, "where") { break } else if isIdent(k), name == nil || isPunct(k - 1, 58) {
                    name = word(k)
                }
                if isPunct(k, 60) { let next = skipGenerics(k); if next > k { k = next; continue } }
                k += 1
                steps += 1
            }
            pending = Scope(kind: .type, name: name)
        } else if isWord(j, "macro_rules"), isPunct(j + 1, 33) {
            add(j + 2, .function)
        } else if isWord(j, "let") {
            if includeLocals, inLocal {
                let k = isWord(j + 1, "mut") ? j + 2 : j + 1
                add(k, .variable)
            }
        } else if inType, top?.members == true, isPunct(j + 1, 58), !isPunct(j + 2, 58) {
            add(j, .field)
        }
    }

    // MARK: Python(들여쓰기)

    mutating func runPython() {
        /// (들여쓰기, 클래스 이름 또는 nil=함수)
        var scopes: [(indent: Int32, name: String?, line: Int, locals: [Int])] = []
        /// 함수 안 지역 선언: 그 함수 범위가 끝날 때 보이는 줄 범위를 채운다
        func closePython(_ scope: (indent: Int32, name: String?, line: Int, locals: [Int]), endLine: Int, _ output: inout [SymbolDeclaration]) {
            for index in scope.locals { output[index].scope = scope.line...max(endLine, scope.line) }
        }
        func addLocal(_ i: Int, _ kind: SymbolKind, _ this: inout DeclarationParser) {
            this.add(i, kind, container: nil)
            if let at = scopes.lastIndex(where: { $0.name == nil }) { scopes[at].locals.append(this.output.count - 1) }
        }
        var depth = 0
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            let lineStart = t.first && depth == 0
            if t.kind == .punct {
                if t.byte == 40 || t.byte == 91 || t.byte == 123 { depth += 1 }
                if t.byte == 41 || t.byte == 93 || t.byte == 125 { depth = max(0, depth - 1) }
            }
            guard lineStart, t.kind == .ident else {
                i += 1
                continue
            }
            while let last = scopes.last, last.indent >= t.indent {
                closePython(scopes.removeLast(), endLine: Int(t.line) - 1, &output)
            }
            let inFunction = scopes.contains { $0.name == nil }
            let classScope = scopes.last.flatMap { $0.name }
            var j = i
            if isWord(j, "async") { j += 1 }
            if isWord(j, "def"), isIdent(j + 1) {
                if inFunction {
                    if includeLocals { addLocal(j + 1, .function, &self) }
                } else if let classScope {
                    output.append(SymbolDeclaration(word(j + 1), line: Int(tokens[j + 1].line), kind: .method, container: classScope))
                } else {
                    add(j + 1, .function)
                }
                scopes.append((t.indent, nil, Int(t.line), []))
            } else if isWord(j, "class"), isIdent(j + 1) {
                if !inFunction || includeLocals {
                    output.append(SymbolDeclaration(word(j + 1), line: Int(tokens[j + 1].line), kind: .class, container: classScope))
                }
                scopes.append((t.indent, word(j + 1), Int(t.line), []))
            } else if isIdent(j), !isWord(j, in: Self.pythonKeywords),
                      (isPunct(j + 1, 61) && !isPunct(j + 2, 61)) || (isPunct(j + 1, 58) && tokens.indices.contains(j + 2) && !tokens[j + 2].first) {
                let name = word(j)
                if inFunction {
                    if includeLocals { addLocal(j, .variable, &self) }
                } else if let classScope {
                    output.append(SymbolDeclaration(name, line: Int(t.line), kind: .property, container: classScope))
                } else if t.indent == 0 {
                    add(j, name == name.uppercased() && name.contains(where: \.isLetter) ? .constant : .variable)
                }
            }
            i += 1
        }
        let lastLine = Int(tokens.last?.line ?? 0)
        while let open = scopes.popLast() { closePython(open, endLine: lastLine, &output) }
    }

    static let pythonKeywords: Set<String> = [
        "if", "elif", "else", "for", "while", "with", "try", "except", "finally", "return", "import", "from", "pass", "raise",
        "del", "global", "nonlocal", "assert", "lambda", "yield", "match", "case", "print",
    ]
}
