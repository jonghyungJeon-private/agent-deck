import AppKit
import CryptoKit
import EditorCore
import TermWire
import WebKit

/// Markdown 미리보기(편집기 화면 안에서 편집 ↔ 미리보기를 바꾼다). 보일 때만 만들고 편집으로 돌아가면 버린다.
///
/// 안전: Markdown 파일은 믿을 수 없는 글(날 HTML·스크립트 포함)이다.
/// 1. 변환은 웹 화면 밖(JavaScriptCore, `MarkdownRenderer`)에서 하고 결과를 허용 목록으로 다시 쓴다(`HTMLSanitizer`).
/// 2. 웹 화면은 페이지 스크립트를 끈다(`allowsContentJavaScript = false`). 앱이 넣는 짧은 스크립트(스크롤·내용 바꾸기)만
///    페이지와 떨어진 세계(`.defaultClient`)에서 돈다.
/// 3. CSP: 스크립트·네트워크 모두 막고 그림은 이 문서 폴더(ctmd://doc)와 data: 만, 글꼴은 앱 것만, 스타일은 우리 것(해시)만.
/// 4. 웹 화면은 다른 곳으로 이동하지 않는다: http·https·mailto 는 기본 앱으로, 로컬 파일 링크는 편집기로 연다.
/// 5. 파일 읽기는 `ctmd:` 처리기만 하고, 문서 폴더 안의 그림 파일만 내준다(파일 URL 접근 권한을 주지 않는다).
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let handler: MarkdownSchemeHandler
    private let pageURL: URL
    private let box = RendererBox()
    /// 처음 그린 뒤 이 위치로 스크롤(문서가 기억한 값)
    private var initialScroll: Double
    private var finishedFirstLoad = false
    private var loading = false
    /// 다 읽으면 initialScroll 로 스크롤하고 보인다
    private var restoreOnFinish = false
    private var generation = 0
    private var latestBody: String?
    /// 로컬 파일 링크(경로)를 눌렀을 때
    var onOpenFile: ((String) -> Void)?
    /// 시험용: 다 그렸을 때
    var onRendered: (() -> Void)?

    private static let queue = DispatchQueue(label: "AgentDeck.markdown", qos: .userInitiated)

    init(path: String, scroll: Double, frame: NSRect) {
        let path = (path as NSString).standardizingPath
        handler = MarkdownSchemeHandler(documentPath: path)
        var components = URLComponents()
        components.scheme = MarkdownSchemeHandler.scheme
        components.host = MarkdownSchemeHandler.documentHost
        components.path = path
        pageURL = components.url ?? URL(string: "ctmd://doc/")!
        initialScroll = scroll

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent() // 쿠키·저장소를 디스크에 남기지 않는다
        configuration.setURLSchemeHandler(handler, forURLScheme: MarkdownSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = EditorStyle.background.cgColor
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground") // 처음 그리기 전 흰 화면이 번쩍이지 않게
        webView.underPageBackgroundColor = EditorStyle.background
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.isHidden = true // 첫 그림·스크롤 맞춘 뒤 보인다
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 지금 버퍼 내용을 그린다(변환은 뒤에서). 이미 떠 있으면 스크롤을 그대로 두고 내용만 바꾼다.
    func show(markdown: String) {
        generation += 1
        let generation = self.generation
        let box = self.box
        Self.queue.async {
            if box.renderer == nil, let script = MarkdownPage.converterScript {
                box.renderer = MarkdownRenderer(script: script)
            }
            let body = box.renderer?.html(markdown) ?? MarkdownPage.missingConverter
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation else { return }
                self.apply(body)
            }
        }
    }

    private func apply(_ body: String) {
        latestBody = body
        handler.setPage(MarkdownPage.document(body: body))
        if finishedFirstLoad, !loading {
            replaceBody(body)
        } else if !loading {
            load()
        } // 읽는 중이면 다 읽은 뒤(didFinish) 새 내용인지 보고 바꾼다
    }

    private func load() {
        loading = true
        restoreOnFinish = true
        webView.load(URLRequest(url: pageURL))
    }

    /// 다시 읽지 않고 본문만 바꾼다(스크롤 유지). 안 되면 다시 읽는다.
    private func replaceBody(_ body: String) {
        let version = handler.pageVersion
        webView.callAsyncJavaScript("document.querySelector('main').innerHTML = html; return 1", arguments: ["html": body],
                                    in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.handler.markServed(version)
                self.onRendered?()
            case .failure:
                self.rememberScroll { [weak self] y in
                    self?.initialScroll = y
                    self?.load()
                }
            }
        }
    }

    /// 지금 스크롤 위치(페이지 세로 px)
    func rememberScroll(_ done: @escaping (Double) -> Void) {
        guard finishedFirstLoad else { return done(initialScroll) }
        webView.evaluateJavaScript("window.scrollY", in: nil, in: .defaultClient) { [initialScroll] result in
            if case .success(let value) = result, let y = value as? Double { done(y) } else { done(initialScroll) }
        }
    }

    /// 화면에서 뺀다. 스크롤 위치를 알려 준 뒤 웹 화면을 놓는다(웹 콘텐츠 프로세스 메모리를 돌려준다).
    func close(remember: @escaping (Double) -> Void) {
        generation += 1
        webView.navigationDelegate = nil
        removeFromSuperview()
        let webView = self.webView
        rememberScroll { y in
            remember(y)
            webView.stopLoading()
            webView.removeFromSuperview()
        }
    }

    // MARK: - 시험용

    var debugSummary: String {
        "preview loaded=\(finishedFirstLoad) loading=\(loading) visible=\(!webView.isHidden) url=\(webView.url?.absoluteString ?? "-") "
            + "pageVersion=\(handler.pageVersion) served=\(handler.servedVersion) bytes=\(handler.pageSize) "
            + "images=\(handler.servedImages) blocked=\(handler.blockedRequests) links=\(Self.debugLinks.suffix(5).joined(separator: ","))"
    }

    static var debugLinks: [String] = []

    /// 지금 페이지 HTML(거른 결과)을 파일로
    func debugDump(to path: String) {
        try? handler.pageData.write(to: URL(fileURLWithPath: path))
    }

    /// 시험용: 거르지 않은 marked 결과를 그대로 넣는다(CSP·스크립트 끄기만으로 막히는지 확인)
    func debugShowUnsanitized(markdown: String) {
        let box = self.box
        Self.queue.async {
            if box.renderer == nil, let script = MarkdownPage.converterScript { box.renderer = MarkdownRenderer(script: script) }
            let raw = box.renderer?.convert(markdown) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.generation += 1
                self.handler.setPage(MarkdownPage.document(body: raw))
                self.load()
            }
        }
    }

    func debugEvaluate(_ script: String, _ done: @escaping (String) -> Void) {
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): done("\(value)")
            case .failure(let error): done("error \(error.localizedDescription)")
            }
        }
    }

    func debugSnapshot(to path: String, _ done: @escaping (Bool) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return done(false) }
            done((try? png.write(to: URL(fileURLWithPath: path))) != nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame == true else {
            // 새 창·하위 틀은 열지 않는다(링크면 아래 규칙대로 처리)
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url { openLink(url) }
            return decisionHandler(.cancel)
        }
        if isPage(url) {
            switch navigationAction.navigationType {
            case .linkActivated, .backForward:
                // 같은 문서 안 #제목 이동만(다시 읽지 않는다)
                return decisionHandler(url.fragment != nil ? .allow : .cancel)
            case .other, .reload:
                return decisionHandler(.allow)
            default:
                return decisionHandler(.cancel)
            }
        }
        if navigationAction.navigationType == .linkActivated { openLink(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        finishedFirstLoad = true
        // 읽는 동안 내용이 또 바뀌었으면 본문만 바꾼다
        if let latestBody, handler.servedVersion < handler.pageVersion {
            replaceBody(latestBody)
        }
        guard restoreOnFinish else {
            onRendered?()
            return
        }
        restoreOnFinish = false
        let y = initialScroll
        webView.evaluateJavaScript("window.scrollTo(0, \(Int(y))); 1", in: nil, in: .defaultClient) { [weak self] _ in
            webView.isHidden = false
            self?.onRendered?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        webView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        webView.isHidden = false
    }

    /// 웹 콘텐츠 프로세스가 죽으면(메모리 압박 등) 다시 읽는다
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishedFirstLoad = false
        load()
    }

    private func isPage(_ url: URL) -> Bool {
        url.scheme == MarkdownSchemeHandler.scheme && url.host == MarkdownSchemeHandler.documentHost
            && (url.path as NSString).standardizingPath == handler.documentPath
    }

    /// 누른 링크: 웹은 기본 앱으로, 로컬 파일은 편집기로. 그 밖(다른 scheme, 폴더, 없는 파일)은 무시한다.
    private func openLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        Self.debugLinks.append("\(scheme):\(url.host ?? "")\(url.path)")
        switch scheme {
        case "http", "https", "mailto":
            if AgentDeckEnv.isOn("DEBUG") {
                print("markdown-link external \(url.absoluteString)")
                fflush(stdout)
                return
            }
            NSWorkspace.shared.open(url)
        case MarkdownSchemeHandler.scheme where url.host == MarkdownSchemeHandler.documentHost:
            let path = (url.path as NSString).standardizingPath
            var isDirectory: ObjCBool = false
            guard path != handler.documentPath, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return }
            // 이 콜백 안에서 화면을 바꾸지 않게 다음 차례에
            DispatchQueue.main.async { [weak self] in self?.onOpenFile?(path) }
        default:
            break
        }
    }
}

/// 변환기는 뷰마다 하나(미리보기를 닫으면 함께 놓는다). 변환 큐에서만 만진다.
private final class RendererBox {
    var renderer: MarkdownRenderer?
}

// MARK: - ctmd: 처리기

/// `ctmd://doc/<문서 절대 경로>` = 미리보기 페이지, 같은 폴더(아래)의 그림 = 그 파일, `ctmd://app/fonts/<이름>` = 앱 글꼴.
/// 그 밖은 모두 거절한다. 그림은 문서 폴더 밖(../, 절대 경로, 밖을 가리키는 링크)은 내주지 않는다.
final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ctmd"
    static let documentHost = "doc"
    static let appHost = "app"
    static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "bmp": "image/bmp", "ico": "image/x-icon", "avif": "image/avif",
    ]
    static let fonts: Set<String> = ["JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf",
                                     "D2Coding-Ver1.3.2-20180524.ttf", "D2CodingBold-Ver1.3.2-20180524.ttf"]
    static let maxImageBytes = 20 << 20

    let documentPath: String
    /// 그림을 내줄 폴더(링크를 푼 실제 경로)
    private let directory: String
    private(set) var pageData = Data()
    private(set) var pageVersion = 0
    private(set) var servedVersion = 0
    private(set) var servedImages = 0
    private(set) var blockedRequests = 0
    var pageSize: Int { pageData.count }

    init(documentPath: String) {
        self.documentPath = documentPath
        directory = Self.resolved((documentPath as NSString).deletingLastPathComponent)
    }

    func setPage(_ html: String) {
        pageData = Data(html.utf8)
        pageVersion += 1
    }

    func markServed(_ version: Int) { servedVersion = max(servedVersion, version) }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        switch url.host {
        case Self.documentHost?:
            let path = (url.path as NSString).standardizingPath
            if path == documentPath {
                servedVersion = pageVersion
                respond(task, url, pageData, type: "text/html; charset=utf-8", csp: MarkdownPage.contentSecurityPolicy)
            } else if let (data, type) = image(at: path) {
                servedImages += 1
                respond(task, url, data, type: type)
            } else {
                fail(task)
            }
        case Self.appHost?:
            let name = url.lastPathComponent
            guard url.path == "/fonts/" + name, Self.fonts.contains(name),
                  let fileURL = Bundle.main.resourceURL?.appendingPathComponent("Fonts").appendingPathComponent(name),
                  let data = try? Data(contentsOf: fileURL) else { return fail(task) }
            respond(task, url, data, type: "font/ttf")
        default:
            fail(task)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// 문서 폴더 안의 그림 파일만
    private func image(at path: String) -> (Data, String)? {
        guard let type = Self.imageTypes[(path as NSString).pathExtension.lowercased()] else { return nil }
        let real = Self.resolved(path)
        guard real.hasPrefix(directory + "/"),
              let size = (try? FileManager.default.attributesOfItem(atPath: real)[.size]) as? NSNumber,
              size.intValue <= Self.maxImageBytes,
              let data = try? Data(contentsOf: URL(fileURLWithPath: real)) else { return nil }
        return (data, type)
    }

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ data: Data, type: String, csp: String? = nil) {
        var headers = ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store",
                       "X-Content-Type-Options": "nosniff"]
        if let csp { headers["Content-Security-Policy"] = csp }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return fail(task)
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask) {
        blockedRequests += 1
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

// MARK: - 페이지

/// 미리보기 페이지 틀과 모양(어두운 테마, 터미널과 같은 색). 본문 글은 시스템 글꼴(한글은 Apple SD Gothic Neo), 코드는 JetBrains Mono + D2Coding.
enum MarkdownPage {
    /// 넣어 둔 변환기(앱 묶음 Resources/Markdown). 한 번 읽어 둔다.
    static let converterScript: String? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Markdown/marked.umd.js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static let missingConverter = "<p class=\"notice\">Markdown 변환기(Resources/Markdown/marked.umd.js)를 찾지 못했습니다. "
        + "scripts/build-term-proto.sh 로 만든 앱에서 열어 주세요.</p>"

    static func document(body: String) -> String {
        "<!doctype html><html lang=\"ko\"><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(metaPolicy)\">"
            + "<meta name=\"color-scheme\" content=\"dark\"><meta name=\"referrer\" content=\"no-referrer\">"
            + "<style>\(css)</style></head><body><main>\(body)</main></body></html>"
    }

    /// 스크립트·네트워크·틀·폼은 막고, 그림은 문서 폴더(ctmd:)와 data: 만, 스타일은 아래 css 만(해시)
    static let policyCore = "default-src 'none'; script-src 'none'; img-src ctmd: data:; font-src ctmd:; "
        + "style-src '\(styleHash)'; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'"
    static let metaPolicy = policyCore
    static let contentSecurityPolicy = policyCore + "; frame-ancestors 'none'"

    static let styleHash: String = {
        "sha256-" + Data(SHA256.hash(data: Data(css.utf8))).base64EncodedString()
    }()

    private static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    static let css: String = {
        let bg = hex(TermAppearance.background)
        let text = hex(EditorStyle.text)
        let strong = hex(TermAppearance.textPrimary)
        let dim = hex(TermAppearance.textDim)
        let border = hex(TermAppearance.border)
        let chrome = hex(TermAppearance.chrome)
        let raised = hex(TermAppearance.chromeRaised)
        let accent = hex(TermAppearance.accent)
        let selection = hex(EditorStyle.selection)
        // 웹 화면은 다른 프로세스라 앱에 등록한 글꼴을 못 본다 → 앱에 넣은 D2Coding 을 한글이 있을 때만 받아 쓴다
        let hangulRange = "unicode-range:U+1100-11FF,U+3130-318F,U+AC00-D7AF"
        let mono = "\"CT Mono\", \"CT Hangul\", \"D2Coding\", \"NanumGothicCoding\", ui-monospace, Menlo, monospace"
        let check = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M3.5 8.4l3 3 6-7' "
            + "fill='none' stroke='%23\(bg.dropFirst())' stroke-width='2.3' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E"
        return """
        @font-face{font-family:"CT Mono";src:url("ctmd://app/fonts/JetBrainsMono-Regular.ttf");font-weight:400;font-style:normal}
        @font-face{font-family:"CT Mono";src:url("ctmd://app/fonts/JetBrainsMono-Bold.ttf");font-weight:700;font-style:normal}
        @font-face{font-family:"CT Mono";src:url("ctmd://app/fonts/JetBrainsMono-Italic.ttf");font-weight:400;font-style:italic}
        @font-face{font-family:"CT Hangul";src:url("ctmd://app/fonts/D2Coding-Ver1.3.2-20180524.ttf");font-weight:400;\(hangulRange)}
        @font-face{font-family:"CT Hangul";src:url("ctmd://app/fonts/D2CodingBold-Ver1.3.2-20180524.ttf");font-weight:700;\(hangulRange)}
        :root{color-scheme:dark}
        html{background:\(bg)}
        body{margin:0;background:\(bg);color:\(text);font:15px/1.75 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Helvetica Neue",sans-serif;
        -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;word-break:keep-all;overflow-wrap:break-word}
        main{max-width:860px;margin:0 auto;padding:30px 44px 120px}
        main>:first-child{margin-top:0!important}
        main:empty::before{content:"빈 문서입니다";color:\(dim)}
        p,ul,ol,dl,table,pre,blockquote,details,figure{margin:0 0 16px}
        h1,h2,h3,h4,h5,h6{color:\(strong);font-weight:650;line-height:1.35;margin:30px 0 14px;letter-spacing:-.01em}
        h1{font-size:1.95em;padding-bottom:.32em;border-bottom:1px solid \(border)}
        h2{font-size:1.45em;padding-bottom:.28em;border-bottom:1px solid \(border)}
        h3{font-size:1.22em}h4{font-size:1.06em}h5{font-size:.96em}h6{font-size:.9em;color:\(dim)}
        a{color:\(accent);text-decoration:none}a:hover{text-decoration:underline;text-underline-offset:3px}
        a:not([href]){color:inherit}
        strong,b{color:\(strong);font-weight:650}
        del,s,strike{color:\(dim)}
        hr{height:1px;border:0;background:\(border);margin:30px 0}
        code,kbd,samp,pre,tt{font-family:\(mono)}
        :not(pre)>code{font-size:.86em;background:\(raised);border:1px solid \(border);border-radius:5px;padding:.1em .38em;color:\(strong)}
        pre{background:\(chrome);border:1px solid \(border);border-radius:8px;padding:14px 16px;overflow:auto;line-height:1.55}
        pre code{font-size:13px;color:\(text);white-space:pre;word-break:normal}
        blockquote{margin-left:0;padding:2px 0 2px 16px;border-left:3px solid \(accent)80;color:#a7adb8}
        blockquote>:last-child,li>:last-child,details>:last-child{margin-bottom:0}
        ul,ol{padding-left:1.7em}li+li{margin-top:.28em}li>ul,li>ol{margin:.28em 0 0}li>p{margin:0 0 8px}
        li::marker{color:\(dim)}
        li:has(>input[type=checkbox]){list-style:none}
        input[type=checkbox]{-webkit-appearance:none;appearance:none;width:15px;height:15px;margin:0 .55em 0 -1.45em;vertical-align:-2px;
        border:1.5px solid \(dim);border-radius:4px;background:transparent}
        input[type=checkbox]:checked{background:\(accent) url("\(check)") center/12px no-repeat;border-color:\(accent)}
        table{border-collapse:collapse;display:block;width:max-content;max-width:100%;overflow:auto;font-size:.94em;line-height:1.55}
        th,td{border:1px solid \(border);padding:7px 13px}
        th{background:\(raised);color:\(strong);font-weight:600}
        tr:nth-child(2n) td{background:#2b3038}
        img{max-width:100%;border-radius:4px}
        .remote-image{display:inline-block;font-size:.84em;line-height:1.6;color:\(dim);border:1px dashed \(border);border-radius:5px;padding:0 .5em}
        .remote-image::before{content:"🖼 "}
        kbd{display:inline-block;padding:.05em .45em;border:1px solid \(border);border-bottom-width:2px;border-radius:5px;background:\(raised);
        color:\(strong);font-size:.8em;line-height:1.5}
        details{border:1px solid \(border);border-radius:8px;padding:8px 14px}
        summary{cursor:pointer;color:\(strong);font-weight:600}
        details[open]>summary{margin-bottom:8px}
        mark{background:#e5c07b40;color:\(strong);border-radius:3px;padding:0 .15em}
        .notice{color:\(dim)}
        ::selection{background:\(selection)}
        """
    }()
}
