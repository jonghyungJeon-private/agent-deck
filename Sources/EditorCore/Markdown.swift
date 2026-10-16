import Foundation
import JavaScriptCore

/// Markdown 파일인지(편집기에 미리보기 단추를 보일지). 확장자로만 본다.
public enum MarkdownFile {
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func isMarkdown(path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// Markdown → 안전한 HTML 조각. 넣어 둔 marked(Resources/Markdown)를 JavaScriptCore 에서 돌리고(웹 화면 밖이라
/// 화면 쪽은 스크립트를 꺼 둘 수 있다), 결과를 `HTMLSanitizer` 로 거른다. 한 큐(스레드)에서만 쓴다.
public final class MarkdownRenderer {
    private let context: JSContext
    private let render: JSValue

    /// script: marked.umd.js 내용. 불러오지 못하면 nil.
    public init?(script: String) {
        guard let context = JSContext() else { return nil }
        context.evaluateScript(script)
        context.evaluateScript(Self.glue)
        guard context.exception == nil,
              let render = context.objectForKeyedSubscript("claudeTermRenderMarkdown"), render.isObject
        else { return nil }
        self.context = context
        self.render = render
    }

    /// marked 가 만든 HTML(거르기 전). 변환 중 오류면 nil.
    public func convert(_ markdown: String) -> String? {
        context.exception = nil
        let value = render.call(withArguments: [markdown])
        guard context.exception == nil, let value, value.isString else { return nil }
        return value.toString()
    }

    /// 거른 HTML 조각. 변환에 실패하면 글을 그대로(이스케이프해) 보인다.
    public func html(_ markdown: String) -> String {
        guard let converted = convert(markdown) else {
            return "<pre><code>" + HTMLSanitizer.escape(markdown) + "</code></pre>"
        }
        return HTMLSanitizer.sanitize(converted)
    }

    /// GFM 켜기 + 제목에 GitHub 식 id(목차 링크 #제목 이 맞게). 같은 이름은 -1, -2 를 붙인다.
    static let glue = #"""
    (function () {
      var seen = Object.create(null);
      function slug(text) {
        var base = String(text).toLowerCase().trim()
          .replace(/<[^>]*>/g, '')
          .replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '')
          .replace(/ /g, '-');
        var id = base, n = seen[base] || 0;
        if (n > 0) id = base + '-' + n;
        seen[base] = n + 1;
        return id;
      }
      marked.use({
        gfm: true,
        breaks: false,
        renderer: {
          heading: function (token) {
            var inner = this.parser.parseInline(token.tokens);
            return '<h' + token.depth + ' id="' + slug(token.text) + '">' + inner + '</h' + token.depth + '>\n';
          }
        }
      });
      globalThis.claudeTermRenderMarkdown = function (src) {
        seen = Object.create(null);
        return marked.parse(src, { async: false });
      };
    })();
    """#
}

/// 믿을 수 없는 HTML(Markdown 속 날 HTML 포함)을 허용 목록으로 다시 쓴다.
/// - 허용한 태그만 이름·속성을 새로 만들어 내보낸다(속성 값은 풀었다가 다시 이스케이프). 그 밖의 `<` 는 모두 `&lt;`.
///   그래서 결과의 `<` 는 모두 여기서 만든 태그다 — 브라우저와 해석이 달라도 새 태그가 생기지 않는다.
/// - script·style·iframe·svg 등은 내용째 버린다. on* 속성·style 은 버린다.
/// - 링크는 http·https·mailto·상대 경로·#만, 그림은 상대 경로·data:image(래스터)만. 원격 그림은 불러오지 않고 이름표로 바꾼다.
public enum HTMLSanitizer {
    static let allowedTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "center", "code", "col", "colgroup", "dd", "del", "details",
        "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img",
        "input", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s", "samp", "small", "span",
        "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u",
        "ul", "var", "wbr",
    ]
    static let voidTags: Set<String> = ["br", "col", "hr", "img", "input", "wbr"]
    /// 여는 태그부터 닫는 태그까지 통째로 버린다(스크립트 글 등이 화면에 보이지 않게)
    static let droppedWithContent: Set<String> = [
        "script", "style", "iframe", "object", "embed", "applet", "template", "noscript", "textarea", "title", "xmp",
        "noembed", "noframes", "frameset", "svg", "math", "select", "head", "audio", "video",
    ]
    static let globalAttributes: Set<String> = ["id", "title", "align", "lang", "dir", "class"]
    static let tagAttributes: [String: Set<String>] = [
        "a": ["href", "name"],
        "img": ["src", "alt", "width", "height"],
        "ol": ["start", "reversed", "type"],
        "li": ["value"],
        "td": ["colspan", "rowspan"],
        "th": ["colspan", "rowspan"],
        "col": ["span"],
        "colgroup": ["span"],
        "details": ["open"],
        "input": ["type", "checked", "disabled"],
    ]
    static let linkSchemes: Set<String> = ["http", "https", "mailto"]
    static let imageDataTypes = ["data:image/png", "data:image/jpeg", "data:image/jpg", "data:image/gif", "data:image/webp"]

    public static func sanitize(_ html: String) -> String {
        let s = Array(html.utf8)
        let n = s.count
        var out = [UInt8]()
        out.reserveCapacity(n + n / 8)
        var i = 0
        while i < n {
            let c = s[i]
            guard c == UInt8(ascii: "<") else {
                // 글은 그대로(이미 이스케이프된 글이거나 날 HTML 의 글 — `<` 만 아니면 태그가 될 수 없다)
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < n else {
                append(&out, "&lt;")
                i += 1
                continue
            }
            let next = s[i + 1]
            if next == UInt8(ascii: "!") {
                // 주석 <!-- … -->, <!DOCTYPE …> 등은 버린다
                if match(s, i, "<!--") {
                    i = find(s, "-->", from: i + 2).map { $0 + 3 } ?? n
                } else {
                    i = find(s, ">", from: i + 2).map { $0 + 1 } ?? n
                }
                continue
            }
            if next == UInt8(ascii: "?") {
                i = find(s, ">", from: i + 2).map { $0 + 1 } ?? n
                continue
            }
            if next == UInt8(ascii: "/") {
                guard i + 2 < n else {
                    append(&out, "&lt;/")
                    i += 2
                    continue
                }
                guard isAlpha(s[i + 2]) else {
                    // </> · </ 1> 같은 것: 브라우저도 버린다
                    i = find(s, ">", from: i + 2).map { $0 + 1 } ?? n
                    continue
                }
                guard let tag = parseTag(s, i + 2) else { break } // 끝나지 않은 태그: 나머지를 버린다
                i = tag.end
                if allowedTags.contains(tag.name), !voidTags.contains(tag.name) { append(&out, "</\(tag.name)>") }
                continue
            }
            guard isAlpha(next) else {
                append(&out, "&lt;")
                i += 1
                continue
            }
            guard let tag = parseTag(s, i + 1) else { break }
            i = tag.end
            if droppedWithContent.contains(tag.name) {
                i = closingTagEnd(s, name: tag.name, from: i) ?? n
                continue
            }
            guard allowedTags.contains(tag.name) else { continue } // 태그만 버리고 안의 글은 남긴다
            if let rebuilt = rebuild(tag) { append(&out, rebuilt) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - 태그 읽기(HTML 토큰화 규칙을 간단히 따른다)

    struct Tag {
        var name: String
        var attributes: [(name: String, value: String)]
        var end: Int
    }

    /// start: `<` 또는 `</` 바로 뒤. 태그가 끝나기 전에 글이 끝나면 nil.
    static func parseTag(_ s: [UInt8], _ start: Int) -> Tag? {
        let n = s.count
        var i = start
        while i < n, !isSpace(s[i]), s[i] != UInt8(ascii: "/"), s[i] != UInt8(ascii: ">") { i += 1 }
        let name = lowercased(s[start..<i])
        var attributes: [(name: String, value: String)] = []
        while true {
            while i < n, isSpace(s[i]) || s[i] == UInt8(ascii: "/") { i += 1 }
            guard i < n else { return nil }
            if s[i] == UInt8(ascii: ">") { return Tag(name: name, attributes: attributes, end: i + 1) }
            let nameStart = i
            i += 1 // 첫 글자는 = 이어도 이름(규칙과 같게)
            while i < n, !isSpace(s[i]), s[i] != UInt8(ascii: "/"), s[i] != UInt8(ascii: ">"), s[i] != UInt8(ascii: "=") { i += 1 }
            let attributeName = lowercased(s[nameStart..<i])
            while i < n, isSpace(s[i]) { i += 1 }
            var value = ""
            if i < n, s[i] == UInt8(ascii: "=") {
                i += 1
                while i < n, isSpace(s[i]) { i += 1 }
                guard i < n else { return nil }
                let quote = s[i]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    i += 1
                    let valueStart = i
                    while i < n, s[i] != quote { i += 1 }
                    guard i < n else { return nil }
                    value = String(decoding: s[valueStart..<i], as: UTF8.self)
                    i += 1
                } else if quote != UInt8(ascii: ">") {
                    let valueStart = i
                    while i < n, !isSpace(s[i]), s[i] != UInt8(ascii: ">") { i += 1 }
                    value = String(decoding: s[valueStart..<i], as: UTF8.self)
                }
            }
            // 같은 속성이 또 오면 첫 것만(브라우저와 같게)
            if !attributes.contains(where: { $0.name == attributeName }) {
                attributes.append((attributeName, value))
            }
        }
    }

    /// `</name` 으로 시작하는 닫는 태그 끝(대소문자 무시). 없으면 nil.
    static func closingTagEnd(_ s: [UInt8], name: String, from: Int) -> Int? {
        let needle = Array(("</" + name).utf8)
        var i = from
        while i + needle.count <= s.count {
            if s[i] == UInt8(ascii: "<"), lowercased(s[i..<(i + needle.count)]) == "</" + name {
                let after = i + needle.count
                if after >= s.count || isSpace(s[after]) || s[after] == UInt8(ascii: ">") || s[after] == UInt8(ascii: "/") {
                    return find(s, ">", from: after).map { $0 + 1 } ?? s.count
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - 다시 쓰기

    static func rebuild(_ tag: Tag) -> String? {
        let name = tag.name
        let allowed = tagAttributes[name] ?? []
        var parts: [String] = []
        for (attribute, raw) in tag.attributes where globalAttributes.contains(attribute) || allowed.contains(attribute) {
            let value = decodeEntities(raw)
            switch attribute {
            case "href":
                guard let url = safeLink(value) else { continue }
                parts.append(attr("href", url))
            case "src":
                switch imageSource(value) {
                case .allowed(let url):
                    parts.append(attr("src", url))
                case .remote(let url):
                    let alt = tag.attributes.first { $0.name == "alt" }.map { decodeEntities($0.value) } ?? ""
                    return "<span class=\"remote-image\" title=\"" + escape("원격 그림은 불러오지 않습니다: " + url) + "\">"
                        + escape(alt.isEmpty ? "원격 그림" : alt) + "</span>"
                case .blocked:
                    return nil
                }
            case "class":
                let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).filter { token in
                    token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
                }
                guard !tokens.isEmpty else { continue }
                parts.append(attr("class", tokens.joined(separator: " ")))
            case "type":
                if name == "input" {
                    guard value.lowercased() == "checkbox" else { return nil }
                    parts.append(attr("type", "checkbox"))
                } else if name == "ol", ["1", "a", "A", "i", "I"].contains(value) {
                    parts.append(attr("type", value))
                }
            case "width", "height":
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "%") }) else { continue }
                parts.append(attr(attribute, value))
            case "start", "value", "colspan", "rowspan", "span":
                guard !value.isEmpty, value.count < 8, value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { continue }
                parts.append(attr(attribute, value))
            case "align":
                let lower = value.lowercased()
                guard ["left", "center", "right", "justify"].contains(lower) else { continue }
                parts.append(attr("align", lower))
            case "dir":
                let lower = value.lowercased()
                guard ["ltr", "rtl", "auto"].contains(lower) else { continue }
                parts.append(attr("dir", lower))
            case "checked", "open", "reversed":
                parts.append(attribute)
            case "disabled":
                break // input 은 아래에서 늘 붙인다
            default:
                parts.append(attr(attribute, value))
            }
        }
        if name == "img", !tag.attributes.contains(where: { $0.name == "src" }) { return nil }
        if name == "input" {
            guard tag.attributes.contains(where: { $0.name == "type" }) else { return nil }
            parts.append("disabled")
        }
        return "<" + name + parts.map { " " + $0 }.joined() + ">"
    }

    static func attr(_ name: String, _ value: String) -> String { name + "=\"" + escape(value) + "\"" }

    /// 링크로 쓸 수 있는 주소(정리한 값). 안 되면 nil.
    static func safeLink(_ value: String) -> String? {
        let url = cleanURL(value)
        guard !url.isEmpty, !url.hasPrefix("//"), !url.hasPrefix("\\") else { return nil }
        if url.hasPrefix("#") { return url }
        if let scheme = scheme(of: url) { return linkSchemes.contains(scheme) ? url : nil }
        return url
    }

    enum ImageSource: Equatable { case allowed(String), remote(String), blocked }

    static func imageSource(_ value: String) -> ImageSource {
        let url = cleanURL(value)
        guard !url.isEmpty, !url.hasPrefix("\\") else { return .blocked }
        if url.hasPrefix("//") { return .remote("https:" + url) }
        guard let scheme = scheme(of: url) else { return .allowed(url) }
        switch scheme {
        case "http", "https": return .remote(url)
        case "data":
            let lower = url.lowercased()
            return imageDataTypes.contains { lower.hasPrefix($0 + ";") || lower.hasPrefix($0 + ",") } ? .allowed(url) : .blocked
        default: return .blocked
        }
    }

    /// 브라우저가 주소를 읽을 때처럼: 앞뒤 제어 문자·공백을 떼고, 탭·줄바꿈은 어디서든 지운다
    static func cleanURL(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        scalars.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }

    /// `scheme:` 꼴이면 소문자 scheme, 아니면(상대 경로) nil
    static func scheme(of url: String) -> String? {
        var name = ""
        for scalar in url.unicodeScalars {
            if scalar == ":" { return name.isEmpty ? nil : name.lowercased() }
            let ascii = scalar.isASCII
            let ok = ascii && (CharacterSet.letters.contains(scalar) || (!name.isEmpty && (CharacterSet.decimalDigits.contains(scalar)
                || scalar == "+" || scalar == "-" || scalar == ".")))
            guard ok else { return nil }
            name.unicodeScalars.append(scalar)
        }
        return nil
    }

    // MARK: - 글자 단위 도움

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "tab": "\t", "newline": "\n", "colon": ":", "sol": "/", "lpar": "(", "rpar": ")", "period": ".",
    ]

    /// 속성 값의 문자 참조를 푼다(숫자·흔한 이름). 못 푼 것은 글자 그대로 남는다 — 다시 이스케이프하므로
    /// 브라우저도 그 글자 그대로 읽는다(그래서 여기서 판단한 값과 브라우저가 쓰는 값이 같다).
    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let scalars = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "&" else {
                out.append(scalars[i])
                i += 1
                continue
            }
            var j = i + 1
            if j < scalars.count, scalars[j] == "#" {
                j += 1
                let hex = j < scalars.count && (scalars[j] == "x" || scalars[j] == "X")
                if hex { j += 1 }
                let digitsStart = j
                while j < scalars.count, j - digitsStart < 8,
                      hex ? scalars[j].properties.isASCIIHexDigit : ("0"..."9").contains(scalars[j]) { j += 1 }
                if j > digitsStart {
                    let digits = String(String.UnicodeScalarView(scalars[digitsStart..<j]))
                    let code = UInt32(digits, radix: hex ? 16 : 10) ?? 0xFFFD
                    let scalar = (code == 0 ? nil : Unicode.Scalar(code)) ?? "\u{FFFD}"
                    out.append(scalar)
                    if j < scalars.count, scalars[j] == ";" { j += 1 }
                    i = j
                    continue
                }
            } else {
                while j < scalars.count, j - i <= 10, scalars[j].isASCII, CharacterSet.alphanumerics.contains(scalars[j]) { j += 1 }
                if j < scalars.count, scalars[j] == ";",
                   let decoded = namedEntities[String(String.UnicodeScalarView(scalars[(i + 1)..<j])).lowercased()] {
                    out.append(contentsOf: decoded.unicodeScalars)
                    i = j + 1
                    continue
                }
            }
            out.append("&")
            i += 1
        }
        return String(out)
    }

    private static func append(_ out: inout [UInt8], _ text: String) { out.append(contentsOf: text.utf8) }

    private static func match(_ s: [UInt8], _ at: Int, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard at + bytes.count <= s.count else { return false }
        return Array(s[at..<(at + bytes.count)]) == bytes
    }

    private static func find(_ s: [UInt8], _ text: String, from: Int) -> Int? {
        let bytes = Array(text.utf8)
        var i = from
        while i + bytes.count <= s.count {
            if s[i] == bytes[0], Array(s[i..<(i + bytes.count)]) == bytes { return i }
            i += 1
        }
        return nil
    }

    private static func isAlpha(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 12 || c == 13 }

    private static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }
}
