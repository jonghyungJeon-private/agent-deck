import Foundation

// MARK: - 커서 아래 이름

public enum Identifier {
    /// $ 를 이름 글자로 쓰는 언어(Kotlin·Swift 는 문자열 틀 기호)
    public static func allowsDollar(_ language: SyntaxLanguage?) -> Bool {
        switch language {
        case .java, .javascript, .typescript, .shell: return true
        default: return false
        }
    }

    @inline(__always) static func isPart(_ c: unichar, dollar: Bool) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || (dollar && c == 36)
            || (c > 127 && c != 0x00A0 && !(c >= 0x2000 && c <= 0x206F) && !(c >= 0x3000 && c <= 0x303F) && c != 0xFEFF)
    }

    /// location(UTF-16) 의 이름 범위. 커서가 이름 바로 뒤에 있어도 그 이름(IntelliJ 처럼). 숫자로 시작하면 nil.
    public static func range(in text: NSString, at location: Int, language: SyntaxLanguage?) -> NSRange? {
        let length = text.length
        guard length > 0 else { return nil }
        let dollar = allowsDollar(language)
        var at = min(max(location, 0), length)
        if at == length || !isPart(text.character(at: at), dollar: dollar) {
            guard at > 0, isPart(text.character(at: at - 1), dollar: dollar) else { return nil }
            at -= 1
        }
        var start = at
        while start > 0, isPart(text.character(at: start - 1), dollar: dollar) { start -= 1 }
        var end = at + 1
        while end < length, isPart(text.character(at: end), dollar: dollar) { end += 1 }
        let first = text.character(at: start)
        if first >= 48 && first <= 57 { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// 이름 앞이 . 인지(obj.name — 받는 쪽이 있는 참조). this. self. 는 받는 쪽 없음으로 본다.
    public static func isQualified(_ text: NSString, range: NSRange) -> Bool {
        var i = range.location - 1
        while i >= 0, text.character(at: i) == 32 || text.character(at: i) == 9 { i -= 1 }
        guard i >= 0, text.character(at: i) == 46 else { return false }
        if i >= 1, text.character(at: i - 1) == 46 { return false } // .. 범위
        var end = i
        while end > 0, text.character(at: end - 1) == 32 { end -= 1 }
        var start = end
        while start > 0, isPart(text.character(at: start - 1), dollar: false) { start -= 1 }
        let receiver = text.substring(with: NSRange(location: start, length: end - start))
        return receiver != "this" && receiver != "self"
    }

    /// obj.name 의 obj(?. !!. 도). 받는 쪽이 이름이 아니면(호출 결과 등) nil.
    public static func receiver(_ text: NSString, range: NSRange) -> String? {
        var i = range.location - 1
        while i >= 0, text.character(at: i) == 32 || text.character(at: i) == 9 { i -= 1 }
        guard i >= 0, text.character(at: i) == 46 else { return nil }
        i -= 1
        while i >= 0, text.character(at: i) == 63 || text.character(at: i) == 33 { i -= 1 } // ?. !!.
        while i >= 0, text.character(at: i) == 32 { i -= 1 }
        let end = i + 1
        while i >= 0, isPart(text.character(at: i), dollar: true) { i -= 1 }
        let start = i + 1
        guard end > start else { return nil }
        let word = text.substring(with: NSRange(location: start, length: end - start))
        guard let first = word.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return nil }
        return word
    }

    /// 받는 쪽 이름의 타입 어림(LSP 없이): 대문자로 시작하면 그 자체(정적·companion),
    /// 아니면 같은 파일의 `obj: Type`(Kotlin·TS·Swift·Python), `Type obj`(Java), `obj = Type(`·`new Type(`.
    public static func receiverType(_ receiver: String, in text: String, language: SyntaxLanguage?) -> String? {
        guard let first = receiver.unicodeScalars.first else { return nil }
        if CharacterSet.uppercaseLetters.contains(first) { return receiver }
        if receiver == "this" || receiver == "self" || receiver == "it" { return nil }
        let name = NSRegularExpression.escapedPattern(for: receiver)
        var patterns = [
            "\\b\(name)\\s*:\\s*([A-Z][A-Za-z0-9_]*)",
            "\\b\(name)\\s*=\\s*(?:new\\s+)?([A-Z][A-Za-z0-9_]*)\\s*[(<{]",
        ]
        if language == .java || language == nil {
            patterns.insert("\\b([A-Z][A-Za-z0-9_]*)\\s*(?:<[^;=(){}]*>)?\\s+\(name)\\s*[;=,)]", at: 0)
        }
        if language == .go {
            patterns.insert("\\b\(name)\\s+\\*?(?:[a-z][A-Za-z0-9_]*\\.)?([A-Z][A-Za-z0-9_]*)", at: 0)
        }
        let ns = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1 else { continue }
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }

    /// 줄에서 이름이 처음 통째로 나오는 곳(UTF-16, 없으면 nil)
    public static func firstWholeWord(_ name: String, in line: String, language: SyntaxLanguage? = nil) -> Int? {
        let text = line as NSString
        let dollar = allowsDollar(language)
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: name, options: .literal, range: search)
            guard found.location != NSNotFound else { return nil }
            let before = found.location > 0 ? text.character(at: found.location - 1) : 32
            let afterIndex = found.location + found.length
            let after = afterIndex < text.length ? text.character(at: afterIndex) : 32
            if !isPart(before, dollar: dollar), !isPart(after, dollar: dollar) { return found.location }
            search = NSRange(location: found.location + 1, length: text.length - found.location - 1)
        }
        return nil
    }
}

// MARK: - 색인

/// 프로젝트 하나의 선언 색인(가볍게: 이름은 한 번만 들고, 선언은 파일마다 16바이트짜리 줄로).
/// 스레드 안전하지 않다 — 쓰는 쪽이 한 줄(큐)에서만 만진다.
public struct SymbolTable: Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: Int32
        public var line: Int32
        /// 감싸는 타입 이름(-1 = 없음)
        public var container: Int32
        public var kind: SymbolKind
    }

    public struct File: Sendable {
        /// 루트 기준 상대 경로
        public var path: String
        public var stamp: FileStamp
        public var entries: [Entry]
        public var removed = false
    }

    /// 파일이 바뀌었는지 볼 표시(수정 시각·크기)
    public struct FileStamp: Equatable, Sendable {
        public var modified: Double
        public var size: Int
        public init(modified: Double, size: Int) {
            self.modified = modified
            self.size = size
        }
    }

    public private(set) var names: [String] = []
    private var nameIds: [String: Int32] = [:]
    public private(set) var files: [File] = []
    private var fileIds: [String: Int32] = [:]

    public init() {}

    public var fileCount: Int { fileIds.count }
    public var symbolCount: Int { files.reduce(0) { $0 + ($1.removed ? 0 : $1.entries.count) } }

    public func fileId(_ path: String) -> Int32? { fileIds[path] }
    public func stamp(_ path: String) -> FileStamp? { fileIds[path].map { files[Int($0)].stamp } }
    public var paths: [String] { files.filter { !$0.removed }.map(\.path) }

    mutating func intern(_ name: String) -> Int32 {
        if let id = nameIds[name] { return id }
        let id = Int32(names.count)
        names.append(name)
        nameIds[name] = id
        return id
    }

    /// 파일 하나를 (다시) 넣는다
    public mutating func set(_ path: String, stamp: FileStamp, declarations: [SymbolDeclaration]) {
        var entries: [Entry] = []
        entries.reserveCapacity(declarations.count)
        for d in declarations {
            entries.append(Entry(name: intern(d.name), line: Int32(d.line), container: d.container.map { intern($0) } ?? -1,
                                 kind: d.kind))
        }
        if let id = fileIds[path] {
            files[Int(id)] = File(path: path, stamp: stamp, entries: entries)
        } else {
            fileIds[path] = Int32(files.count)
            files.append(File(path: path, stamp: stamp, entries: entries))
        }
    }

    public mutating func remove(_ path: String) {
        guard let id = fileIds.removeValue(forKey: path) else { return }
        files[Int(id)].entries = []
        files[Int(id)].removed = true
    }

    public struct Hit: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var kind: SymbolKind
        public var name: String
        public var container: String?
    }

    func hit(_ file: File, _ e: Entry) -> Hit {
        Hit(path: file.path, line: Int(e.line), kind: e.kind, name: names[Int(e.name)],
            container: e.container >= 0 ? names[Int(e.container)] : nil)
    }

    /// 이름이 똑같은 선언 전부
    public func lookup(_ name: String) -> [Hit] {
        guard let id = nameIds[name] else { return [] }
        var hits: [Hit] = []
        for file in files where !file.removed {
            for e in file.entries where e.name == id { hits.append(hit(file, e)) }
        }
        return hits
    }

    /// ⌘O: 이름 맞추기(낙타 혹). 점수 높은 순, 같으면 타입 먼저·짧은 경로.
    public func search(_ pattern: String, limit: Int = 200, cancelled: () -> Bool = { false }) -> [(hit: Hit, score: Int, matched: [Int])] {
        let query = pattern.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let matcher = FuzzyMatcher(query)
        var scored: [Int32: (Int, [Int])] = [:]
        for (index, name) in names.enumerated() {
            if index & 4095 == 0, cancelled() { return [] }
            if let m = matcher.match(name) { scored[Int32(index)] = (m.score, m.positions) }
        }
        guard !scored.isEmpty else { return [] }
        var results: [(hit: Hit, score: Int, matched: [Int])] = []
        for file in files where !file.removed {
            for e in file.entries {
                guard let (score, positions) = scored[e.name] else { continue }
                // 생성자는 타입과 같은 이름이라 목록을 어지럽힌다
                if e.kind == .constructor { continue }
                results.append((hit(file, e), score + (e.kind.isType ? 30 : 0), positions))
            }
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.hit.path.count != $1.hit.path.count { return $0.hit.path.count < $1.hit.path.count }
            return ($0.hit.path, $0.hit.line) < ($1.hit.path, $1.hit.line)
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }
}

// MARK: - 낙타 혹 맞추기

/// IntelliJ 식 이름 맞추기: 대문자는 낱말 머리에, 소문자는 지금 낱말 안(건너뛰기 가능) 또는 다음 낱말 머리에.
/// "UsrSvc" → UserService, "usvc" → UserService, "findby" → findById.
public struct FuzzyMatcher {
    let pattern: [UInt8]
    let lower: [UInt8]

    public init(_ pattern: String) {
        self.pattern = Array(pattern.utf8.filter { $0 != 32 && $0 != 42 })
        lower = self.pattern.map(Self.lowercase)
    }

    @inline(__always) static func lowercase(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
    @inline(__always) static func isUpper(_ c: UInt8) -> Bool { c >= 65 && c <= 90 }
    @inline(__always) static func isLower(_ c: UInt8) -> Bool { c >= 97 && c <= 122 }
    @inline(__always) static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// 낱말 머리: 맨 앞, 소문자·숫자 뒤 대문자, _·- 뒤, 글자 뒤 숫자 시작
    static func wordStarts(_ name: [UInt8]) -> [Bool] {
        var starts = [Bool](repeating: false, count: name.count)
        for i in name.indices {
            if i == 0 { starts[i] = true; continue }
            let p = name[i - 1], c = name[i]
            if c == 95 || c == 45 || c == 36 { continue }
            if p == 95 || p == 45 || p == 36 || p == 46 { starts[i] = true }
            else if isUpper(c), isLower(p) || isDigit(p) { starts[i] = true }
            else if isUpper(c), i + 1 < name.count, isUpper(p), isLower(name[i + 1]) { starts[i] = true } // HTTPServer 의 S
            else if isDigit(c), !isDigit(p) { starts[i] = true }
        }
        return starts
    }

    public func match(_ candidate: String) -> (score: Int, positions: [Int])? {
        guard !pattern.isEmpty else { return nil }
        var copy = candidate
        return copy.withUTF8 { buffer -> (score: Int, positions: [Int])? in
            let n = buffer.count
            guard n >= pattern.count, n < 256 else { return nil }
            // 빠른 거르기: 대소문자 무시 부분 수열
            var pi = 0
            for c in buffer where pi < lower.count && Self.lowercase(c) == lower[pi] { pi += 1 }
            guard pi == lower.count else { return nil }
            let name = Array(buffer)
            let starts = Self.wordStarts(name)
            var positions: [Int] = []
            positions.reserveCapacity(pattern.count)
            guard search(name, starts, 0, 0, -1, &positions) else { return nil }
            return (score(name, starts, positions), positions)
        }
    }

    /// 되짚기 맞추기(이름이 짧아 충분히 빠르다). last = 지난번 맞춘 위치
    private func search(_ name: [UInt8], _ starts: [Bool], _ pi: Int, _ from: Int, _ last: Int, _ positions: inout [Int]) -> Bool {
        if pi == pattern.count { return true }
        let p = pattern[pi], pl = lower[pi]
        var i = from
        while i < name.count {
            let c = name[i]
            if Self.lowercase(c) == pl {
                let isStart = starts[i]
                // 바로 이어지면 언제나 가능, 낱말 머리면 가능, 대문자 패턴은 낱말 머리(또는 바로 이음)만,
                // 소문자는 지난번과 같은 낱말 안이면 건너뛰어도 된다
                let consecutive = i == last + 1
                let sameWord = last >= 0 && !(last + 1...i).contains { starts[$0] }
                let ok: Bool
                if Self.isUpper(p) {
                    ok = isStart || (consecutive && Self.isUpper(c))
                } else if pi == 0 {
                    ok = isStart
                } else {
                    ok = consecutive || isStart || sameWord
                }
                if ok {
                    positions.append(i)
                    if search(name, starts, pi + 1, i + 1, i, &positions) { return true }
                    positions.removeLast()
                }
            }
            i += 1
        }
        return false
    }

    private func score(_ name: [UInt8], _ starts: [Bool], _ positions: [Int]) -> Int {
        var score = 1_000
        if positions.count == name.count {
            score += 5_000 // 이름 전체
            if zip(pattern, name).allSatisfy({ $0 == $1 }) { score += 1_000 }
        } else if positions == Array(0..<positions.count) {
            score += 2_000 // 앞부분
            if zip(pattern, name).allSatisfy({ $0 == $1 }) { score += 300 }
        }
        for (k, p) in positions.enumerated() {
            if starts[p] { score += 30 }
            if k > 0, positions[k - 1] == p - 1 { score += 15 }
            if name[p] == pattern[k] { score += 3 }
        }
        score -= name.count * 2
        // 맞추지 않은 낱말(혹)이 많을수록 뒤로(usvc 는 UserSessionValidatorCache 보다 UserService)
        let matched = Set(positions)
        let unmatchedWords = starts.indices.filter { starts[$0] && !matched.contains($0) && $0 > (positions.first ?? 0) }.count
        score -= unmatchedWords * 40
        // 이름 중간 낱말에서 시작하면 뒤로(EvtSvc: EventService·eventService 가 WeeklyCarViewEventService 보다 먼저)
        let skippedWords = starts.indices.filter { starts[$0] && $0 < (positions.first ?? 0) }.count
        score -= skippedWords * 25
        return score
    }
}

// MARK: - 사용 위치

public struct Usage: Equatable, Sendable {
    /// 줄(0부터)·줄 안 위치(UTF-16)
    public var line: Int
    public var column: Int
    public var text: String
}

public enum UsageFinder {
    /// 이름이 통째로(주석·문자열 밖) 나오는 곳. 바이트로 먼저 찾고, 있는 파일만 낱말로 나눠 확인한다.
    public static func find(_ name: String, in bytes: UnsafeBufferPointer<UInt8>, language: SyntaxLanguage, limit: Int = 500) -> [Usage] {
        let needle = Array(name.utf8)
        guard !needle.isEmpty, contains(bytes, needle) else { return [] }
        let tokens = SymbolLexer.lex(bytes, rules: LexRules.of(language))
        var result: [Usage] = []
        var lineStarts: [Int32: Int] = [:]
        for t in tokens where t.kind == .ident && Int(t.end - t.start) == needle.count {
            var same = true
            for k in 0..<needle.count where bytes[Int(t.start) + k] != needle[k] { same = false; break }
            guard same else { continue }
            // 줄 시작·끝
            let start: Int
            if let known = lineStarts[t.line] { start = known } else {
                var s = Int(t.start)
                while s > 0, bytes[s - 1] != 10 { s -= 1 }
                lineStarts[t.line] = s
                start = s
            }
            var end = Int(t.end)
            while end < bytes.count, bytes[end] != 10 { end += 1 }
            let lineText = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
            let prefix = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<Int(t.start)]), as: UTF8.self)
            result.append(Usage(line: Int(t.line), column: (prefix as NSString).length,
                                text: lineText.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))))
            if result.count >= limit { break }
        }
        return result
    }

    /// 바이트 열에 들어 있는지(memmem)
    public static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = bytes.baseAddress, !needle.isEmpty, bytes.count >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { n in memmem(base, bytes.count, n.baseAddress!, n.count) != nil }
    }
}

// MARK: - 가져오기(import)로 순서 정하기

public struct ImportHint: Equatable, Sendable {
    /// 가져온 이름(마지막 마디). 별표면 nil.
    public var name: String?
    /// 경로 꼴(com/x/UserService, 별표면 com/x). TS 상대 경로는 절대 경로(확장자 뺌).
    public var path: String
    /// 상대 경로로 가리키는 파일(TS·JS)
    public var isFile: Bool

    public init(name: String?, path: String, isFile: Bool) {
        self.name = name
        self.path = path
        self.isFile = isFile
    }
}

public enum ImportHints {
    /// 파일 앞부분의 import 문. directory 는 지금 파일의 폴더(TS 상대 경로 풀기).
    public static func parse(_ text: String, language: SyntaxLanguage?, directory: String) -> [ImportHint] {
        var hints: [ImportHint] = []
        var lines = 0
        text.enumerateLines { line, stop in
            lines += 1
            if lines > 400 { stop = true; return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch language {
            case .kotlin?, .java?:
                guard trimmed.hasPrefix("import ") else { return }
                var body = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("static ") { body = String(body.dropFirst(7)) }
                body = body.replacingOccurrences(of: ";", with: "")
                var alias: String?
                if let asRange = body.range(of: " as ") {
                    alias = body[asRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    body = String(body[..<asRange.lowerBound])
                }
                let parts = body.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init)
                guard let last = parts.last else { return }
                if last == "*" {
                    hints.append(ImportHint(name: nil, path: parts.dropLast().joined(separator: "/"), isFile: false))
                } else {
                    hints.append(ImportHint(name: alias ?? last, path: parts.joined(separator: "/"), isFile: false))
                }
            case .typescript?, .javascript?:
                // import { A, B as C } from './x'  /  import D from '../y'
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("export "), let fromRange = trimmed.range(of: " from ") else { return }
                let spec = trimmed[fromRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ;'\""))
                guard spec.hasPrefix(".") else { return }
                let resolved = ((directory as NSString).appendingPathComponent(spec) as NSString).standardizingPath
                let clause = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<fromRange.lowerBound]
                let names = clause.replacingOccurrences(of: "{", with: ",").replacingOccurrences(of: "}", with: ",")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "type" }
                for item in names {
                    let words = item.split(separator: " ").map(String.init)
                    let name = words.count >= 3 && words[1] == "as" ? words[2] : words.last.map { $0 == "*" ? "" : $0 } ?? ""
                    hints.append(ImportHint(name: name.isEmpty ? nil : name, path: resolved, isFile: true))
                }
            case .python?:
                // from a.b import C, D
                guard trimmed.hasPrefix("from "), let importRange = trimmed.range(of: " import ") else { return }
                let module = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<importRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                guard !module.hasPrefix(".") else { return }
                let path = module.replacingOccurrences(of: ".", with: "/")
                for item in trimmed[importRange.upperBound...].split(separator: ",") {
                    let name = item.split(separator: " ").last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    hints.append(ImportHint(name: name, path: path, isFile: true))
                }
            default:
                break
            }
        }
        return hints
    }
}

// MARK: - 패키지

public enum PackageInfo {
    /// 파일 앞부분의 `package a.b.c`(Kotlin·Java, ; 뺌). 없으면 nil.
    public static func parse(_ text: String) -> String? {
        var result: String?
        var lines = 0
        text.enumerateLines { line, stop in
            lines += 1
            if lines > 200 { stop = true; return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package ") else {
                // 선언이 시작되면 그만(주석·주석 블록·import·빈 줄만 앞에 온다)
                if trimmed.hasPrefix("import ") || trimmed.hasPrefix("class ") || trimmed.hasPrefix("public ") { stop = true }
                return
            }
            let name = trimmed.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: " ;\t"))
            result = name.split(separator: " ").first.map(String.init)
            stop = true
        }
        return result
    }
}

// MARK: - 후보 순서

public struct NavigationCandidate: Equatable, Sendable {
    /// 절대 경로
    public var path: String
    public var line: Int
    public var kind: SymbolKind
    public var name: String
    public var container: String?

    public init(path: String, line: Int, kind: SymbolKind, name: String, container: String? = nil) {
        self.path = path
        self.line = line
        self.kind = kind
        self.name = name
        self.container = container
    }
}

public enum CandidateRanker {
    public enum Tier: Int, Comparable, Sendable {
        case other = 0, sameModule, sameDirectory, importedPackage, imported, sameFile
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public static func tier(_ c: NavigationCandidate, from file: String, name: String, imports: [ImportHint],
                            receiverType: String? = nil) -> Tier {
        if c.path == file { return .sameFile }
        let noExt = (c.path as NSString).deletingPathExtension
        let dir = (c.path as NSString).deletingLastPathComponent
        // 멤버를 감싼 클래스를 명시 import 했으면 그 클래스 파일의 멤버는 import 한 것(같은 이름 다른 패키지 클래스보다 앞)
        if let container = c.container,
           let hint = imports.first(where: { !$0.isFile && $0.name == container && ($0.path as NSString).lastPathComponent == container }),
           noExt.hasSuffix("/" + hint.path) {
            return .imported
        }
        // 받는 쪽 타입의 멤버면 그 타입을 import 했는지로 본다
        let name = receiverType != nil && c.container == receiverType ? receiverType! : name
        for hint in imports where hint.name == name || hint.name == nil {
            if hint.isFile {
                if noExt == hint.path || noExt == hint.path + "/index" || (hint.name != nil && noExt.hasSuffix("/" + hint.path)) {
                    return .imported
                }
            } else if let imported = hint.name, imported == name {
                // com/x/UserService → .../com/x/UserService.kt 거나, 최상위 함수면 .../com/x/ 폴더
                if noExt.hasSuffix("/" + hint.path) { return .imported }
                let package = (hint.path as NSString).deletingLastPathComponent
                if !package.isEmpty, dir.hasSuffix("/" + package) { return .imported }
            } else if hint.name == nil, dir.hasSuffix("/" + hint.path) {
                return .importedPackage
            }
        }
        let fileDir = (file as NSString).deletingLastPathComponent
        if dir == fileDir { return .sameDirectory }
        if commonComponents(dir, fileDir) >= 4 { return .sameModule }
        return .other
    }

    static func commonComponents(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: "/"), y = b.split(separator: "/")
        var n = 0
        while n < x.count, n < y.count, x[n] == y[n] { n += 1 }
        return n
    }

    static func isTest(_ path: String) -> Bool {
        path.contains("/test/") || path.contains("/tests/") || path.contains("/__tests__/") || path.contains("Test.")
            || path.contains(".test.") || path.contains(".spec.")
    }

    /// 순서: 같은 파일 → 가져온 것 → 같은 패키지 → 같은 폴더 → 가까운 모듈 → 나머지. 시험 코드는 같은 줄에서 뒤로.
    /// receiverType(obj.name 의 obj 타입 어림)이 있으면 그 타입의 멤버가 맨 앞.
    public static func rank(_ candidates: [NavigationCandidate], from file: String, name: String,
                            imports: [ImportHint], receiverType: String? = nil) -> [(candidate: NavigationCandidate, tier: Tier)] {
        let fromTest = isTest(file)
        let fileDir = (file as NSString).deletingLastPathComponent
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert("\($0.path):\($0.line):\($0.kind.rawValue)").inserted }
        return unique.map { ($0, tier($0, from: file, name: name, imports: imports, receiverType: receiverType)) }
            .sorted { a, b in
                if let receiverType {
                    let ma = a.0.container == receiverType, mb = b.0.container == receiverType
                    if ma != mb { return ma }
                }
                if a.1 != b.1 { return a.1 > b.1 }
                let ta = isTest(a.0.path) != fromTest, tb = isTest(b.0.path) != fromTest
                if ta != tb { return !ta }
                let ca = commonComponents((a.0.path as NSString).deletingLastPathComponent, fileDir)
                let cb = commonComponents((b.0.path as NSString).deletingLastPathComponent, fileDir)
                if ca != cb { return ca > cb }
                if a.0.kind.isType != b.0.kind.isType { return a.0.kind.isType }
                if a.0.path != b.0.path { return a.0.path < b.0.path }
                return a.0.line < b.0.line
            }
    }

    /// obj.name 에서 obj 의 타입이 있을 수 있는 패키지(점 표기). 명시 import 가 있으면 그 패키지 하나,
    /// 없으면 지금 파일 패키지(같은 패키지는 import 없이 쓴다) + 별표 import 패키지. 패키지를 모르면 빈 집합(제한 없음).
    public static func allowedPackages(for receiverType: String, imports: [ImportHint], currentPackage: String?) -> Set<String> {
        if let explicit = imports.first(where: { !$0.isFile && $0.name == receiverType }) {
            let package = (explicit.path as NSString).deletingLastPathComponent
            return [package.replacingOccurrences(of: "/", with: ".")]
        }
        var result = Set(imports.filter { !$0.isFile && $0.name == nil }.map { $0.path.replacingOccurrences(of: "/", with: ".") })
        if let currentPackage { result.insert(currentPackage) }
        return result
    }

    /// 받는 쪽 타입이 정해지면 그 클래스의 멤버(companion 포함)와 그 클래스 파일의 최상위 선언만 남긴다.
    /// packages = 후보 파일의 package(읽은 것). allowed 가 비어 있으면 패키지는 보지 않는다. 맞는 것이 없으면 빈 목록(부르는 쪽이 이름 전체로 돌아간다).
    public static func restrict(_ candidates: [NavigationCandidate], receiverType: String, allowed: Set<String>,
                                packages: [String: String]) -> [NavigationCandidate] {
        candidates.filter { c in
            let stem = ((c.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard c.container == receiverType || (c.container == nil && stem == receiverType) else { return false }
            guard !allowed.isEmpty else { return true }
            guard let package = packages[c.path] else { return false }
            return allowed.contains(package)
        }
    }

    /// 목록 없이 바로 갈 하나(없으면 nil): 후보 하나, 받는 쪽 없는 참조인데 같은 파일에 하나, 가져온 것이 하나.
    public static func decisive(_ ranked: [(candidate: NavigationCandidate, tier: Tier)], qualified: Bool,
                                receiverType: String? = nil) -> NavigationCandidate? {
        if ranked.count == 1 { return ranked[0].candidate }
        if let receiverType {
            // 받는 쪽 타입의 멤버가 하나거나, 그중 import 한 타입 것이 하나
            let members = ranked.filter { $0.candidate.container == receiverType }
            if members.count == 1 { return members[0].candidate }
            let imported = members.filter { $0.tier == .imported || $0.tier == .sameFile }
            if imported.count == 1 { return imported[0].candidate }
            if !members.isEmpty { return nil }
        }
        let same = ranked.filter { $0.tier == .sameFile }
        if !qualified, same.count == 1 { return same[0].candidate }
        let imported = ranked.filter { $0.tier == .imported }
        if imported.count == 1, same.isEmpty || qualified { return imported[0].candidate }
        return nil
    }
}

// MARK: - 뒤로·앞으로

/// IntelliJ 식 이동 기록: 건너뛰기 직전 위치를 쌓고, 뒤로 가면 지금 위치를 앞으로 쪽에 쌓는다.
public struct NavigationHistory<Location: Equatable> {
    public private(set) var back: [Location] = []
    public private(set) var forward: [Location] = []
    public let limit: Int

    public init(limit: Int = 50) { self.limit = limit }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// 건너뛰기 직전: from 을 쌓고 앞으로 기록을 지운다
    public mutating func record(_ from: Location) {
        if back.last != from { back.append(from) }
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    /// 뒤로: 갈 곳(없으면 nil). current 는 앞으로 쪽에 쌓는다.
    public mutating func goBack(from current: Location?) -> Location? {
        guard var target = back.popLast() else { return nil }
        // 지금 자리와 같은 기록은 건너뛴다
        while target == current, let next = back.popLast() { target = next }
        if target == current { return nil }
        if let current { forward.append(current) }
        return target
    }

    public mutating func goForward(from current: Location?) -> Location? {
        guard var target = forward.popLast() else { return nil }
        while target == current, let next = forward.popLast() { target = next }
        if target == current { return nil }
        if let current { back.append(current) }
        return target
    }
}
