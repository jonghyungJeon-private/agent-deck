@testable import EditorCore
import Foundation
import XCTest

final class MarkdownFileTests: XCTestCase {
    func testExtensions() {
        for path in ["/a/README.md", "/a/b.MD", "/x.markdown", "/x.mdown", "/x.mkd", "notes.Markdown"] {
            XCTAssertTrue(MarkdownFile.isMarkdown(path: path), path)
        }
        for path in ["/a/b.mdx", "/a/md", "/a/b.txt", "/a/.md/b.swift", "/a/b.md.swift", "/a/b"] {
            XCTAssertFalse(MarkdownFile.isMarkdown(path: path), path)
        }
        XCTAssertEqual(SyntaxLanguage.detect(path: "/x.mdown"), .markdown)
        XCTAssertEqual(SyntaxLanguage.detect(path: "/x.mkd"), .markdown)
    }
}

final class HTMLSanitizerTests: XCTestCase {
    private func clean(_ html: String) -> String { HTMLSanitizer.sanitize(html) }

    func testKeepsMarkdownOutput() {
        let html = "<h2 id=\"a-b\">A <em>b</em></h2>\n<p><a href=\"https://x.dev/?a=1&amp;b=2\">x</a> <code>&lt;tag&gt;</code></p>"
            + "<table>\n<thead>\n<tr>\n<th align=\"left\">a</th></tr></thead></table><hr><br>"
        XCTAssertEqual(clean(html), html)
    }

    func testDropsScriptsAndDangerousContainers() {
        XCTAssertEqual(clean("a<script>alert(1)</script>b"), "ab")
        XCTAssertEqual(clean("a<SCRIPT type=x>alert('</p>')</ScRiPt >b"), "ab")
        XCTAssertEqual(clean("a<script>never closed"), "a")
        XCTAssertEqual(clean("<svg><script>alert(5)</script></svg>ok"), "ok")
        XCTAssertEqual(clean("<style>body{display:none}</style>ok"), "ok")
        XCTAssertEqual(clean("<iframe src=\"https://e.com\"></iframe>ok"), "ok")
        XCTAssertEqual(clean("<noscript><img src=x onerror=alert(1)></noscript>ok"), "ok")
        XCTAssertEqual(clean("<!-- <script>x</script> -->ok"), "ok")
    }

    func testStripsEventHandlersAndStyles() {
        XCTAssertEqual(clean("<p align=\"center\" style=\"color:red\" onclick=\"alert(4)\">x</p>"), "<p align=\"center\">x</p>")
        XCTAssertEqual(clean("<img src=./a.png onerror=alert(2) alt=\"그림\">"), "<img src=\"./a.png\" alt=\"그림\">")
        XCTAssertEqual(clean("<img src=x onerror=\"alert(2)\">"), "<img src=\"x\">")
        XCTAssertEqual(clean("<div/onmouseover=alert(1)>x</div>"), "<div>x</div>")
        // 따옴표 안의 > 는 태그를 끝내지 않는다
        XCTAssertEqual(clean("<a title=\"a>b\" onclick=x>t</a>"), "<a title=\"a&gt;b\">t</a>")
    }

    func testUnknownTagsDroppedButTextKept() {
        XCTAssertEqual(clean("<form action=x><button>누름</button></form>"), "누름")
        XCTAssertEqual(clean("<meta http-equiv=refresh content=0><base href=//evil>ok"), "ok")
        XCTAssertEqual(clean("1 < 2 and <3"), "1 &lt; 2 and &lt;3")
        XCTAssertEqual(clean("unterminated <a href=\"x"), "unterminated ")
    }

    func testLinks() {
        XCTAssertEqual(clean("<a href=\"javascript:alert(1)\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"jav&#x09;ascript:alert(3)\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"jav\tascript:alert(3)\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\" JaVaScRiPt:alert(1)\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"javascript&colon;alert(1)\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"vbscript:x\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"data:text/html,<script>\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"file:///etc/passwd\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"//evil.com/x\">x</a>"), "<a>x</a>")
        XCTAssertEqual(clean("<a href=\"mailto:a@b.c\">m</a>"), "<a href=\"mailto:a@b.c\">m</a>")
        XCTAssertEqual(clean("<a href=\"../docs/other.md#x\">o</a>"), "<a href=\"../docs/other.md#x\">o</a>")
        XCTAssertEqual(clean("<a href=\"#%ED%91%9C\">표</a>"), "<a href=\"#%ED%91%9C\">표</a>")
        // 풀지 못한 참조는 글자 그대로 남아(&amp;) 브라우저도 같은 값을 읽는다
        XCTAssertEqual(clean("<a href=\"jav&Unknown;script:x\">x</a>"), "<a href=\"jav&amp;Unknown;script:x\">x</a>")
    }

    func testImages() {
        XCTAssertEqual(clean("<img src=\"https://e.com/t.png\" alt=\"배지\">"),
                       "<span class=\"remote-image\" title=\"원격 그림은 불러오지 않습니다: https://e.com/t.png\">배지</span>")
        XCTAssertEqual(clean("<img src=\"data:image/png;base64,AAAA\">"), "<img src=\"data:image/png;base64,AAAA\">")
        XCTAssertEqual(clean("<img src=\"data:image/svg+xml,<svg onload=alert(1)>\">"), "")
        XCTAssertEqual(clean("<img src=\"javascript:alert(1)\">"), "")
        XCTAssertEqual(clean("<img alt=x>"), "")
    }

    func testTaskListCheckbox() {
        XCTAssertEqual(clean("<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> a</li>"),
                       "<li><input checked type=\"checkbox\" disabled> a</li>")
        XCTAssertEqual(clean("<input type=\"text\" value=\"x\">"), "")
        XCTAssertEqual(clean("<input type=checkbox>"), "<input type=\"checkbox\" disabled>")
    }

    func testClassTokensFiltered() {
        XCTAssertEqual(clean("<code class=\"language-swift\">x</code>"), "<code class=\"language-swift\">x</code>")
        XCTAssertEqual(clean("<code class=\"a&quot; onload=&quot;x b\">x</code>"), "<code class=\"b\">x</code>")
    }
}

final class MarkdownRendererTests: XCTestCase {
    private static let renderer: MarkdownRenderer? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Markdown/marked.umd.js")
        guard let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MarkdownRenderer(script: script)
    }()

    private func render(_ markdown: String) throws -> String {
        let renderer = try XCTUnwrap(Self.renderer, "Resources/Markdown/marked.umd.js 를 불러오지 못함")
        return renderer.html(markdown)
    }

    func testGitHubFlavored() throws {
        let html = try render("""
        # 제목 하나
        ## 코드 블록
        ## 코드 블록

        | a | b |
        |:--|--:|
        | 1 | 2 |

        - [x] 끝남
        - [ ] 남음

        ~~지움~~ https://example.com

        ```swift
        let a = "<b>"
        ```
        """)
        XCTAssertTrue(html.contains("<h1 id=\"제목-하나\">제목 하나</h1>"), html)
        XCTAssertTrue(html.contains("<h2 id=\"코드-블록\">"), html)
        XCTAssertTrue(html.contains("<h2 id=\"코드-블록-1\">"), html)
        XCTAssertTrue(html.contains("<th align=\"left\">a</th>"), html)
        XCTAssertTrue(html.contains("<td align=\"right\">2</td>"), html)
        XCTAssertTrue(html.contains("<input checked type=\"checkbox\" disabled>"), html)
        XCTAssertTrue(html.contains("<del>지움</del>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">https://example.com</a>"), html)
        XCTAssertTrue(html.contains("<code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot;"), html)
    }

    func testRawHTMLIsSanitized() throws {
        let html = try render("""
        <script>alert(1)</script>
        <img src=x onerror="alert(2)">

        [위험](javascript:alert(1)) <details><summary>s</summary>안</details>
        """)
        XCTAssertFalse(html.lowercased().contains("<script"), html)
        XCTAssertFalse(html.contains("onerror"), html)
        XCTAssertFalse(html.contains("javascript:"), html)
        XCTAssertTrue(html.contains("<details><summary>s</summary>"), html)
    }

    func testRepeatedRenderResetsHeadingIds() throws {
        let first = try render("# a")
        let second = try render("# a")
        XCTAssertEqual(first, second)
    }
}
