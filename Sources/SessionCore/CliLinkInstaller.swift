import Foundation
import TermWire

/// "터미널에서도 agentdeck 쓰기": `~/.local/bin/agentdeck` → 앱 묶음의 `Contents/Helpers/agentdeck` 심볼릭 링크.
/// AgentDeck 안의 칸은 설치 없이 `agentdeck` 를 쓰므로(CliBinding) 이것은 앱 밖 터미널용이다.
/// 이 앱의 링크(묶음 안 Helpers/agentdeck 를 가리키는 것)만 고치고 지운다. 이미 다른 파일·링크가 있으면 덮지 않는다.
public struct CliLinkInstaller {
    public let link: URL
    public let target: URL

    public init(link: URL = CliBinding.userLink(), target: URL) {
        self.link = link
        self.target = target
    }

    public enum Status: Equatable {
        case notInstalled
        /// 이 앱을 가리키는 링크
        case installed
        /// 다른 위치의 AgentDeck(앱을 옮김·예전 사본)을 가리키는 이 앱 계열 링크 — 바꿀 수 있다
        case outdated
        /// 사용자가 직접 둔 파일·링크 — 건드리지 않는다
        case userManaged
    }

    public enum InstallerError: LocalizedError {
        case userManaged(String)

        public var errorDescription: String? {
            switch self {
            case .userManaged(let path): return "이미 다른 파일이 있어 덮지 않습니다: \(path)"
            }
        }
    }

    public func status() -> Status {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: link.path) else { return .notInstalled } // 깨진 링크도 "있음"
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fm.destinationOfSymbolicLink(atPath: link.path)
        else { return .userManaged }
        let resolved = destination.hasPrefix("/") ? destination
            : link.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
        if resolved == target.path { return .installed }
        return resolved.hasSuffix("/Contents/Helpers/agentdeck") ? .outdated : .userManaged
    }

    public func install() throws {
        let fm = FileManager.default
        switch status() {
        case .installed: return
        case .userManaged: throw InstallerError.userManaged((link.path as NSString).abbreviatingWithTildeInPath)
        case .outdated: try fm.removeItem(at: link)
        case .notInstalled: break
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// 이 앱의 링크만 지운다. 지웠으면 true.
    @discardableResult
    public func uninstall() throws -> Bool {
        switch status() {
        case .installed, .outdated:
            try FileManager.default.removeItem(at: link)
            return true
        case .notInstalled, .userManaged:
            return false
        }
    }
}
