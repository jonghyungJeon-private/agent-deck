import Foundation

/// 파일 트리 한 폴더의 내용(펼칠 때 한 번 읽는다)
public struct DirectoryEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }

    /// 점으로 시작하는 숨김 파일(흐리게 보인다)
    public var isHidden: Bool { name.hasPrefix(".") }
}

public enum DirectoryListing {
    /// 늘 빼는 이름(.git 은 내용이 많고 볼 일이 없다)
    public static let skipped: Set<String> = [".git", ".DS_Store"]

    /// 폴더 먼저, 그다음 파일. 각각 대소문자 무시 이름순(같으면 원래 이름순).
    public static func sorted(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
    }

    /// 폴더 내용. 읽을 수 없으면 빈 목록. 심볼릭 링크는 가리키는 것이 폴더면 폴더로 본다.
    public static func read(_ path: String) -> [DirectoryEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        else { return [] }
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(urls.count)
        for item in urls {
            let name = item.lastPathComponent
            guard !skipped.contains(name) else { continue }
            let values = try? item.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                var flag: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: item.path, isDirectory: &flag) && flag.boolValue
            }
            entries.append(DirectoryEntry(name: name, isDirectory: isDirectory))
        }
        return sorted(entries)
    }
}
