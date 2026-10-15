import Foundation
import SessionCore

/// 앱 동작 로그(~/Library/Application Support/ClaudeSessions/app.log). 문제를 진단할 때 본다. 1MB 가 넘으면 비운다.
enum AppLog {
    private static let queue = DispatchQueue(label: "ClaudeSessions.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let url = Paths.appSupport.appendingPathComponent("app.log")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1 << 20 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
