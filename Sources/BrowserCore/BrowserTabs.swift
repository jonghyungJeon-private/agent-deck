import Foundation

/// 브라우저 칸 위의 탭 칩. 브라우저가 지금 연 페이지(CDP — 사람이 연 탭도 바로 보인다)에
/// abx 가 적은 탭 정보(이름·작업 공간·누가 열었는지, `tabs.json`)를 붙인다.
/// 순서: AI 작업 공간마다 묶어(main 먼저, 그다음 만든 순서) 브라우저 순서대로, 사람 탭은 맨 뒤.
public enum BrowserTabs {
    public struct Page: Equatable, Sendable {
        public var targetId: String
        public var url: String
        public var title: String
        public init(targetId: String, url: String, title: String) {
            self.targetId = targetId
            self.url = url
            self.title = title
        }
    }

    public struct Chip: Equatable, Sendable {
        public var targetId: String
        /// abx 탭 id(t3) — abx 가 아직 모르는 탭은 nil
        public var tabId: String?
        /// 이름(label) 또는 제목(없으면 주소의 호스트)
        public var text: String
        /// 묶음 이름: 작업 공간 이름, AI 탭인데 공간이 없으면 "main", 사람 탭은 nil
        public var group: String?
        public var users: Bool
        /// AI 가 마지막으로 일한 탭(abx 의 활성 탭) — 사람이 다른 탭을 보고 있을 때 AI 가 어디서 일하는지 보인다
        public var agentHere: Bool
        /// 칸에 보이는 탭
        public var shown: Bool
        public var url: String
        public var title: String
        /// 흉내 내는 기기(abx 가 적은 것) — 없으면 보통 창
        public var device: AbxStatus.Tab.Device? = nil
    }

    public static let main = "main"

    /// keep: 주소는 about:blank 지만 내용이 있는 탭(document.write 등) — 빈 탭으로 치지 않는다
    /// devices: 기기 홀더가 적은 탭마다의 기기(있으면 탭 목록의 것보다 새것 — AbxStatus.devices)
    public static func chips(pages: [Page], tabs: [AbxStatus.Tab], shown: String?, keep: Set<String> = [],
                             devices: [String: AbxStatus.Tab.Device]? = nil) -> [Chip] {
        let known = Dictionary(tabs.map { ($0.targetId, $0) }, uniquingKeysWith: { a, _ in a })
        // Chrome 이 스스로 띄우는 내부 페이지(chrome://newtab 등)는 abx 도 탭으로 치지 않는다
        // AI 의 빈 탭(about:blank, 이름 없음 — abx 가 다음 `tab new`·`open` 에 다시 쓰는 탭)은 보고 있는 탭이 아니면
        // 칩으로 내지 않는다. 사람의 탭·이름 붙은 탭·넘겨받은 탭은 주소가 비어도 남는다(돌아가거나 닫을 수 있게).
        func spare(_ page: Page) -> Bool {
            guard blank(page.url), page.targetId != shown, !keep.contains(page.targetId), let tab = known[page.targetId] else { return false }
            return !tab.isUsers && tab.adopted != true && (tab.label ?? "").isEmpty
        }
        let chips = pages.filter { (!internalPage($0.url) || known[$0.targetId] != nil) && !spare($0) }
            .map { page -> Chip in
            let tab = known[page.targetId]
            // abx 가 모르는 탭은 사람이 연 탭이다(abx 는 자기가 연 탭을 바로 적는다)
            let users = tab.map(\.isUsers) ?? true
            let group: String? = users && tab?.adopted != true ? nil : (tab?.space?.name ?? main)
            return Chip(targetId: page.targetId, tabId: tab?.id, text: text(label: tab?.label, page: page), group: group,
                        users: users, agentHere: tab?.active == true,
                        shown: page.targetId == shown, url: page.url, title: page.title,
                        device: devices.map { $0[page.targetId] } ?? tab?.device)
        }
        let spaceOrder = tabs.compactMap(\.space).reduce(into: [Int: String]()) { $0[$1.id] = $1.name }
            .sorted { $0.key < $1.key }.map(\.value)
        func rank(_ chip: Chip) -> Int {
            guard let group = chip.group else { return Int.max }
            if group == main { return 0 }
            return (spaceOrder.firstIndex(of: group) ?? spaceOrder.count) + 1
        }
        return chips.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    public static func blank(_ url: String) -> Bool { url.isEmpty || url == "about:blank" }

    static func internalPage(_ url: String) -> Bool {
        ["chrome://", "chrome-untrusted://", "devtools://", "chrome-extension://"].contains { url.hasPrefix($0) }
    }

    static func text(label: String?, page: Page) -> String {
        if let label, !label.isEmpty { return label }
        let title = page.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != page.url { return title }
        if let host = URL(string: page.url)?.host, !host.isEmpty { return host }
        return page.url == "about:blank" || page.url.isEmpty ? "빈 탭" : page.url
    }
}
