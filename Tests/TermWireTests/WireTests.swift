import TermWire
import XCTest

final class WireTests: XCTestCase {
    func testFramesSurviveArbitrarySplits() throws {
        let frames = [
            Frame(.list),
            Frame(.output, pane: "A1", bytes: Array("한글 출력\r\n".utf8)),
            Frame(.create, json: CreateRequest(id: "B2", cwd: "/tmp", cols: 80, rows: 24, input: "claude\n")),
        ]
        let stream = frames.flatMap { $0.encoded() }
        // 1바이트씩 잘라 넣어도 같은 메시지가 나와야 한다
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in stream {
            decoder.append([byte])
            while let frame = try decoder.next() { decoded.append(frame) }
        }
        XCTAssertEqual(decoded, frames)
        XCTAssertEqual(decoded[1].paneData?.id, "A1")
        XCTAssertEqual(decoded[1].paneData.map { String(decoding: $0.bytes, as: UTF8.self) }, "한글 출력\r\n")
        XCTAssertEqual(decoded[2].json(CreateRequest.self)?.input, "claude\n")
    }

    func testRejectsOversizedFrame() {
        var decoder = FrameDecoder()
        decoder.append([0x7f, 0xff, 0xff, 0xff, 1])
        XCTAssertThrowsError(try decoder.next())
    }

    func testUnknownTypeIsError() {
        var decoder = FrameDecoder()
        decoder.append([0, 0, 0, 1, 200])
        XCTAssertThrowsError(try decoder.next())
    }
}
