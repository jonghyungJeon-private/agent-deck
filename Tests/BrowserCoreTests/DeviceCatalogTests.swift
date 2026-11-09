import XCTest
@testable import BrowserCore

final class DeviceCatalogTests: XCTestCase {
    /// `abx device list --json` 을 읽는다(모르는 필드 os·model·aliases 는 버린다)
    func testDecodesAbxDeviceList() throws {
        let json = #"""
        {"groups":[{"name":"iPhone","series":[{"name":"iPhone 16","devices":[
          {"id":"iphone-16-pro","name":"iPhone 16 Pro","width":402,"height":874,"scale":3,"kind":"phone","os":"ios"}]}]},
          {"name":"iPad","series":[{"name":"iPad Pro","devices":[
          {"id":"ipad-pro-13-m4","name":"iPad Pro 13 (M4)","detail":"M4·M5","width":1032,"height":1376,"scale":2,"kind":"tablet","os":"ipados"}]}]}],
         "aliases":{"iphone":"iphone-17"}}
        """#
        let catalog = try JSONDecoder().decode(DeviceCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.groups.map(\.name), ["iPhone", "iPad"])
        XCTAssertEqual(catalog.device("ipad-pro-13-m4")?.detail, "M4·M5")
        XCTAssertEqual(catalog.device("iphone-16-pro")?.sizeText, "402×874")
        XCTAssertEqual(catalog.path("ipad-pro-13-m4")?.series, "iPad Pro")
        XCTAssertNil(catalog.device("nope"))
    }

    /// 탭 목록의 기기(abx 가 적은 것) — 예전 abx 의 탭(필드 없음)은 nil
    func testDecodesTabDevice() throws {
        let json = #"""
        [{"id":"t1","targetId":"A","url":"https://a","title":"A","active":true,
          "device":{"id":"galaxy-s25","name":"Galaxy S25","width":780,"height":360,"scale":3,"landscape":true,"kind":"phone"}},
         {"id":"t2","targetId":"B","url":"https://b","title":"B","active":false}]
        """#
        let tabs = try JSONDecoder().decode([AbxStatus.Tab].self, from: Data(json.utf8))
        XCTAssertEqual(tabs[0].device?.name, "Galaxy S25")
        XCTAssertEqual(tabs[0].device?.landscape, true)
        XCTAssertEqual(tabs[0].device?.isMobile, true)
        XCTAssertNil(tabs[1].device)
        let chips = BrowserTabs.chips(pages: [.init(targetId: "A", url: "https://a", title: "A")], tabs: tabs, shown: "A")
        XCTAssertEqual(chips.first?.device?.id, "galaxy-s25")
    }

    func testCustomIdAndRecents() {
        XCTAssertEqual(DeviceCatalog.customId(width: 390, height: 844, scale: 3, mobile: true), "390x844@3,mobile")
        XCTAssertEqual(DeviceCatalog.customId(width: 1280, height: 720, scale: nil, mobile: false), "1280x720")
        XCTAssertEqual(DeviceCatalog.customId(width: 412, height: 915, scale: 2.625, mobile: true), "412x915@2.625,mobile")
        var recents = RecentDevices(ids: ["a", "b"], limit: 3)
        recents.use("c")
        recents.use("a")
        recents.use("d")
        XCTAssertEqual(recents.ids, ["d", "a", "c"])
    }

    /// 기기 테두리 자리: 둘레를 비운 만큼 그림이 작아지고, 마우스 좌표 변환도 같은 자리를 쓴다
    func testViewportInsetKeepsMappingConsistent() {
        let plain = ViewportTransform(bounds: CGSize(width: 400, height: 900), viewport: CGSize(width: 390, height: 844))
        let framed = ViewportTransform(bounds: CGSize(width: 400, height: 900), viewport: CGSize(width: 390, height: 844), inset: 14)
        XCTAssertLessThan(framed.imageRect.height, plain.imageRect.height)
        XCTAssertLessThanOrEqual(framed.imageRect.maxY, 900 - 14 + 0.001)
        let center = CGPoint(x: framed.imageRect.midX, y: framed.imageRect.midY)
        let css = try! XCTUnwrap(framed.cssPoint(center))
        XCTAssertEqual(css.x, 195, accuracy: 0.5)
        XCTAssertEqual(css.y, 422, accuracy: 0.5)
        XCTAssertNil(framed.cssPoint(CGPoint(x: 2, y: 2))) // 테두리를 누르면 페이지가 아니다
    }
}

final class DeviceRecordTests: XCTestCase {
    /// 기기 홀더의 기록이 탭 목록보다 새것: abx 가 아직 적지 않은 사람 팝업도 기기를 보인다
    func testHolderRecordWinsOverTabList() throws {
        let data = Data(#"{"P":{"id":"ipad-air-11","landscape":true,"name":"iPad Air 11","width":1180,"height":820,"scale":2,"kind":"tablet"},"X":{"id":"old"}}"#.utf8)
        let devices = try XCTUnwrap(AbxStateReader.decodeDevices(data))
        XCTAssertEqual(devices["P"]?.width, 1180)
        XCTAssertNil(devices["X"]) // 이름·크기 없는 기록은 버린다
        let tabs = [AbxStatus.Tab(id: "t1", targetId: "A", url: "https://a", title: "A", active: true, openedBy: "agent",
                                  device: .init(id: "iphone-16", name: "iPhone 16", width: 393, height: 852, scale: 3, landscape: false, kind: "phone"))]
        let pages: [BrowserTabs.Page] = [.init(targetId: "A", url: "https://a", title: "A"), .init(targetId: "P", url: "https://a", title: "A")]
        let chips = BrowserTabs.chips(pages: pages, tabs: tabs, shown: "P", devices: devices)
        XCTAssertNil(chips.first { $0.targetId == "A" }?.device) // 기록에 없으면 이제 보통 창
        XCTAssertEqual(chips.first { $0.targetId == "P" }?.device?.name, "iPad Air 11")
        XCTAssertEqual(BrowserTabs.chips(pages: pages, tabs: tabs, shown: "A").first?.device?.id, "iphone-16") // 기록 없는 예전 abx
        // 홀더가 아직 예전 꼴로 적어 둔 기록은 탭 목록의 그 탭 기기로 메운다
        let old = Data(#"{"A":{"id":"iphone-16"}}"#.utf8)
        XCTAssertEqual(AbxStateReader.decodeDevices(old, fallback: tabs)?["A"]?.name, "iPhone 16")
    }
}
