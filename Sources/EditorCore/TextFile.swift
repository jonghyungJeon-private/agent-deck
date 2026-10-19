import Darwin
import Foundation

/// 줄 끝 모양. 편집하는 동안은 \n 하나로 다루고, 저장할 때 원래 모양으로 되돌린다.
/// 섞여 있으면(mixed) 고치지 않고 글을 그대로 둔다(저장해도 원래 줄 끝이 그대로 남는다).
public enum LineEnding: String, Equatable, Sendable {
    case lf, crlf, cr, mixed

    public var label: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        case .mixed: return "섞임"
        }
    }

    /// 처음 보이는 줄 끝들로 정한다. 줄 끝이 없으면 LF.
    public static func detect(_ text: String) -> LineEnding {
        var lf = false, crlf = false, cr = false
        var previousCR = false
        for unit in text.utf8 {
            if unit == 10 {
                if previousCR { crlf = true } else { lf = true }
                previousCR = false
            } else {
                if previousCR { cr = true }
                previousCR = unit == 13
            }
        }
        if previousCR { cr = true }
        switch (lf, crlf, cr) {
        case (false, false, false): return .lf
        case (true, false, false): return .lf
        case (false, true, false): return .crlf
        case (false, false, true): return .cr
        default: return .mixed
        }
    }

    /// 편집용(\n)으로
    public func normalize(_ text: String) -> String {
        switch self {
        case .lf, .mixed: return text
        case .crlf: return text.replacingOccurrences(of: "\r\n", with: "\n")
        case .cr: return text.replacingOccurrences(of: "\r", with: "\n")
        }
    }

    /// 저장용(원래 줄 끝)으로
    public func denormalize(_ text: String) -> String {
        switch self {
        case .lf, .mixed: return text
        // 편집 중 \r\n 이 붙여넣어졌으면 겹치지 않게 먼저 \n 으로
        case .crlf: return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return text.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}

/// 열 수 있는 파일인지
public enum TextFileKind: Equatable, Sendable {
    case text
    /// 앞 8KB 에 NUL 이 있음
    case binary
    /// 너무 큼(바이트)
    case tooLarge(Int)
    /// UTF-8 이 아님
    case notUTF8
}

/// 읽어 들인 글
public struct DecodedText: Equatable, Sendable {
    /// 편집용 글(줄 끝은 \n, mixed 면 그대로)
    public var text: String
    public var lineEnding: LineEnding
    /// UTF-8 BOM 이 있었는지(저장할 때 그대로 붙인다)
    public var hasBOM: Bool
}

public enum TextFile {
    /// 편집기로 여는 최대 크기(이보다 크면 읽기 전용 안내만)
    public static let maxEditableBytes = 5 << 20
    /// NUL 을 찾는 앞부분
    public static let probeBytes = 8 << 10

    /// 파일 크기와 앞부분으로 종류를 정한다(내용 전체가 있으면 UTF-8 인지도 본다)
    public static func classify(size: Int, head: Data, full: Data? = nil) -> TextFileKind {
        if size > maxEditableBytes { return .tooLarge(size) }
        if head.prefix(probeBytes).contains(0) { return .binary }
        if let full, decode(full) == nil { return .notUTF8 }
        return .text
    }

    /// UTF-8(BOM 있어도 됨)로 풀고 줄 끝을 맞춘다. UTF-8 이 아니면 nil.
    public static func decode(_ data: Data) -> DecodedText? {
        var bytes = data
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        if bom { bytes = bytes.dropFirst(3) }
        guard let raw = String(data: bytes, encoding: .utf8) else { return nil }
        let ending = LineEnding.detect(raw)
        return DecodedText(text: ending.normalize(raw), lineEnding: ending, hasBOM: bom)
    }

    /// 저장할 바이트(원래 줄 끝·BOM 으로)
    public static func encode(_ text: String, lineEnding: LineEnding, hasBOM: Bool) -> Data {
        var data = Data()
        if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: Array(lineEnding.denormalize(text).utf8))
        return data
    }

    /// 파일을 읽어 종류를 정한다. 텍스트면 내용도 돌려준다(크거나 바이너리면 앞부분만 읽는다).
    public static func read(path: String) throws -> (kind: TextFileKind, decoded: DecodedText?) {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > maxEditableBytes { return (.tooLarge(size), nil) }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        let kind = classify(size: data.count, head: data.prefix(probeBytes), full: data)
        guard kind == .text, let decoded = decode(data) else { return (kind, nil) }
        return (.text, decoded)
    }

    /// 안전하게 쓴다: 같은 폴더에 임시 파일로 다 쓴 뒤 이름을 바꿔 끼운다(중간에 끊겨도 원본이 반쯤 남지 않게).
    /// 심볼릭 링크면 링크가 가리키는 파일을 바꾸고, 원래 권한(실행 비트 등)을 이어받는다.
    public static func writeAtomically(_ data: Data, to path: String) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let temp = (directory as NSString).appendingPathComponent(".\(name).agentdeck-\(UUID().uuidString.prefix(8))")
        var mode: mode_t = 0o644
        var info = stat()
        let existed = stat(target, &info) == 0
        if existed { mode = info.st_mode & 0o7777 }
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failed: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; failed = errno; return }
                offset += written
            }
        }
        if failed == 0, existed { fchmod(fd, mode) } // umask 로 깎인 권한을 원래대로
        if failed == 0, fsync(fd) != 0 { failed = errno }
        close(fd)
        if failed != 0 {
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: failed) ?? .EIO)
        }
        if rename(temp, target) != 0 {
            let code = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// 디스크의 파일이 바뀌었는지 알아보는 표(수정 시각·크기·inode)
public struct FileFingerprint: Equatable, Sendable {
    public var modified: TimeInterval
    public var size: Int64
    public var inode: UInt64

    public init(modified: TimeInterval, size: Int64, inode: UInt64) {
        self.modified = modified
        self.size = size
        self.inode = inode
    }

    /// 없으면 nil(지워짐)
    public static func of(_ path: String) -> FileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return FileFingerprint(modified: seconds, size: Int64(info.st_size), inode: UInt64(info.st_ino))
    }
}
