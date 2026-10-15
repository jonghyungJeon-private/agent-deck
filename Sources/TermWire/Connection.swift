import Darwin
import Foundation

/// 논블로킹 소켓 하나로 메시지를 주고받는다. 모든 메서드는 만들 때 준 queue 에서 불러야 한다.
public final class Connection {
    /// 상대가 읽지 않아 쌓인 보낼 데이터가 이만큼 넘으면 끊는다(메모리가 끝없이 늘지 않게).
    public static let maxBacklog = 64 << 20

    public let fd: Int32
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private var outbox: [UInt8] = []
    private var outStart = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// 아직 취소 처리가 끝나지 않은 소스 수. 0 이 되어야 fd 를 닫는다.
    private var liveSources = 0
    private var closeRequested = false

    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var isClosed = false

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    public var backlog: Int { outbox.count - outStart }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { self.sourceCancelled() } // 강하게 잡아 두어야 fd 가 꼭 닫힌다
        liveSources += 1
        readSource = source
        source.resume()
    }

    public func send(_ frame: Frame) {
        guard !isClosed else { return }
        outbox.append(contentsOf: frame.encoded())
        flush()
        if backlog > Self.maxBacklog { close() }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        closeRequested = true
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        if liveSources == 0 { Darwin.close(fd) }
        outbox = []
        outStart = 0
        let handler = onClose
        onClose = nil
        onFrame = nil
        handler?()
    }

    private func sourceCancelled() {
        liveSources -= 1
        if liveSources == 0, closeRequested { Darwin.close(fd) }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while !isClosed {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                decoder.append(chunk[0..<count])
                do {
                    while !isClosed, let frame = try decoder.next() { onFrame?(frame) }
                } catch {
                    close()
                    return
                }
                if count < chunk.count { return }
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                return
            } else {
                close() // 0 = 상대가 끊음
                return
            }
        }
    }

    private func flush() {
        while backlog > 0 {
            let written = outbox.withUnsafeBytes { raw in
                write(fd, raw.baseAddress! + outStart, backlog)
            }
            if written > 0 {
                outStart += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                close()
                return
            }
        }
        if backlog == 0 {
            outbox.removeAll(keepingCapacity: outbox.capacity <= 256 << 10)
            outStart = 0
            writeSource?.cancel()
            writeSource = nil
        } else {
            if outStart > 1 << 20 {
                outbox.removeFirst(outStart)
                outStart = 0
            }
            if writeSource == nil {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.flush() }
                source.setCancelHandler { self.sourceCancelled() } // 강하게 잡아 두어야 fd 가 꼭 닫힌다
                liveSources += 1
                writeSource = source
                source.resume()
            }
        }
    }
}
