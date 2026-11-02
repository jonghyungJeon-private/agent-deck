import XCTest
@testable import BrowserCore

final class BrowserTabsTests: XCTestCase {
    /// abx 0.x 의 tabs.json(작업 공간·주인 포함)을 읽는다 — 예전 파일(필드 없음)도
    func testDecodesTabOwnersAndSpaces() throws {
        let json = #"""
        [{"id":"t1","targetId":"A","url":"https://a","title":"A","active":true},
         {"id":"t2","targetId":"B","url":"https://b","title":"B","active":false,"openedBy":"agent","label":"discord","space":{"id":2,"name":"uat"}},
         {"id":"t3","targetId":"C","url":"https://c","title":"C","active":false,"openedBy":"user","adopted":true,"space":{"id":2,"name":"uat"}}]
        """#
        let tabs = try JSONDecoder().decode([AbxStatus.Tab].self, from: Data(json.utf8))
        XCTAssertNil(tabs[0].openedBy)
        XCTAssertFalse(tabs[0].isUsers)
        XCTAssertEqual(tabs[1].label, "discord")
        XCTAssertEqual(tabs[1].space, .init(id: 2, name: "uat"))
        XCTAssertTrue(tabs[2].isUsers)
        XCTAssertEqual(tabs[2].adopted, true)
    }

    /// 칩: 작업 공간마다 묶고(main 먼저, 만든 순서), 사람 탭은 뒤. abx 가 모르는 탭은 사람이 연 탭.
    func testChipsGroupBySpaceWithUserTabsLast() {
        let pages = [
            BrowserTabs.Page(targetId: "U", url: "https://login.example.com/x", title: ""),
            BrowserTabs.Page(targetId: "S3", url: "https://web.telegram.org", title: "Telegram"),
            BrowserTabs.Page(targetId: "M", url: "about:blank", title: "about:blank"),
            BrowserTabs.Page(targetId: "S2", url: "https://discord.com/app", title: "Discord"),
            BrowserTabs.Page(targetId: "K", url: "https://kept.example", title: "Kept"),
        ]
        let tabs = [
            AbxStatus.Tab(id: "t1", targetId: "M", url: "about:blank", title: "", active: false, openedBy: "agent"),
            AbxStatus.Tab(id: "t4", targetId: "S2", url: "", title: "", active: true, label: "discord", openedBy: "agent",
                          space: .init(id: 1, name: "chat")),
            AbxStatus.Tab(id: "t5", targetId: "S3", url: "", title: "", active: false, openedBy: "agent", space: .init(id: 3, name: "uat")),
            AbxStatus.Tab(id: "t6", targetId: "K", url: "", title: "", active: false, openedBy: "user"),
        ]
        let chips = BrowserTabs.chips(pages: pages, tabs: tabs, shown: "S3")
        XCTAssertEqual(chips.map(\.targetId), ["M", "S2", "S3", "U", "K"])
        XCTAssertEqual(chips.map(\.group), ["main", "chat", "uat", nil, nil])
        XCTAssertEqual(chips.map(\.text), ["빈 탭", "discord", "Telegram", "login.example.com", "Kept"])
        XCTAssertEqual(chips.first { $0.agentHere }?.targetId, "S2")
        XCTAssertEqual(chips.first { $0.shown }?.targetId, "S3")
        XCTAssertEqual(chips.filter(\.users).map(\.targetId), ["U", "K"])
        XCTAssertNil(chips.first { $0.targetId == "U" }?.tabId)
    }

    /// Chrome 내부 페이지(chrome://newtab)는 칩이 아니다 — abx 엔진도 탭 목록에서 뺀다
    func testChromeInternalPagesAreNotChips() {
        let chips = BrowserTabs.chips(pages: [.init(targetId: "N", url: "chrome://newtab/", title: "새 탭"),
                                              .init(targetId: "A", url: "about:blank", title: "")],
                                      tabs: [AbxStatus.Tab(id: "t1", targetId: "A", url: "", title: "", active: true, openedBy: "agent")], shown: nil)
        XCTAssertEqual(chips.map(\.targetId), ["A"])
    }

    /// 작업 공간 이전 abx(주인 필드 없음)의 탭은 AI 탭(main)
    func testLegacyTabsAreTheAgents() {
        let chips = BrowserTabs.chips(pages: [.init(targetId: "A", url: "https://a.example", title: "A")],
                                      tabs: [AbxStatus.Tab(id: "t1", targetId: "A", url: "", title: "", active: true)], shown: nil)
        XCTAssertEqual(chips.first?.group, "main")
        XCTAssertEqual(chips.first?.users, false)
    }
}
