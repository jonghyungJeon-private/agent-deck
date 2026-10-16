import Foundation

/// 파일 하나의 git 상태(파일 트리 색). IntelliJ 처럼 한 가지 대표 상태만 쓴다.
public enum GitFileStatus: String, Equatable, Sendable {
    case modified, added, renamed, deleted, untracked, ignored, conflicted

    /// 위 폴더에 "안에 바뀐 것이 있음"을 알릴 상태(무시된 파일은 알리지 않는다)
    public var isChange: Bool { self != .ignored }
}

/// `git status --porcelain=v1 -z --untracked-files=normal --ignored=matching` 결과.
/// 경로는 저장소 맨 위 기준 상대 경로("src/a.swift"). 폴더 항목("scratch/", "build/")은 그 아래 전체에 적용된다.
public struct GitStatusSnapshot: Equatable, Sendable {
    /// 파일(또는 하위 모듈) 상태
    public private(set) var files: [String: GitFileStatus] = [:]
    /// 통째로 추적 안 됨·무시된 폴더(끝의 "/" 뺀 경로)
    public private(set) var folders: [String: GitFileStatus] = [:]
    /// 안에 바뀐 것이 있는 폴더(모든 조상, 맨 위 "" 포함)
    public private(set) var changedFolders: Set<String> = []

    public init() {}

    public var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    /// 경로의 상태. 자기 항목이 없으면 통째로 추적 안 됨·무시된 조상 폴더의 상태를 물려받는다.
    public func status(of path: String) -> GitFileStatus? {
        if let own = files[path] ?? folders[path] { return own }
        guard !folders.isEmpty else { return nil }
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            if let inherited = folders[String(current)] { return inherited }
        }
        return nil
    }

    /// 폴더 안(아래 어디든)에 바뀐 파일이 있는지
    public func containsChanges(_ folder: String) -> Bool { changedFolders.contains(folder) }

    /// 바뀐 파일·폴더 수(무시된 것 뺌)
    public var changeCount: Int {
        files.values.filter(\.isChange).count + folders.values.filter(\.isChange).count
    }

    mutating func record(_ path: String, _ status: GitFileStatus) {
        var path = path
        let isFolder = path.hasSuffix("/")
        if isFolder { path.removeLast() }
        guard !path.isEmpty else { return }
        if isFolder { folders[path] = status } else { files[path] = status }
        guard status.isChange else { return }
        // 조상 폴더 모두에 표시(이미 있으면 그 위도 이미 있다)
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            if !changedFolders.insert(String(current)).inserted { return }
        }
        changedFolders.insert("")
    }
}

public enum GitStatusParser {
    /// -z 형식: 항목마다 "XY 경로\0", 이름 바꿈·복사(R·C)는 "XY 새 경로\0옛 경로\0".
    /// 경로는 따옴표·이스케이프 없이 그대로 나온다(공백·한글 포함).
    public static func parse(_ data: Data) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = fields.startIndex
        while index < fields.endIndex {
            let field = fields[index]
            index += 1
            // "XY " 다음에 경로
            guard field.count > 3 else { continue }
            let bytes = Array(field)
            let x = bytes[0], y = bytes[1]
            guard bytes[2] == UInt8(ascii: " "),
                  let path = String(bytes: bytes[3...], encoding: .utf8) else { continue }
            let isMove = x == UInt8(ascii: "R") || x == UInt8(ascii: "C") || y == UInt8(ascii: "R") || y == UInt8(ascii: "C")
            if isMove, index < fields.endIndex { index += 1 } // 옛 경로는 건너뛴다
            if let status = status(x: x, y: y) { snapshot.record(path, status) }
        }
        return snapshot
    }

    /// X(색인)·Y(작업 폴더) 두 글자 → 대표 상태
    public static func status(x: UInt8, y: UInt8) -> GitFileStatus? {
        let pair = String(bytes: [x, y], encoding: .ascii) ?? ""
        switch pair {
        case "??": return .untracked
        case "!!": return .ignored
        case "DD", "AA", "AU", "UA", "DU", "UD", "UU": return .conflicted
        default: break
        }
        let codes = [Character(UnicodeScalar(x)), Character(UnicodeScalar(y))]
        if codes.contains("U") { return .conflicted }
        if codes.contains("R") { return .renamed }
        if x == UInt8(ascii: "A") || x == UInt8(ascii: "C") { return .added }
        if codes.contains("D") { return .deleted }
        if codes.contains("M") || codes.contains("T") { return .modified }
        return nil
    }
}
