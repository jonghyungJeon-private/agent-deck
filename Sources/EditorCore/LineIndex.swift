import Foundation

/// 줄 시작 위치(UTF-16) 목록. 줄 번호 여백이 매번 처음부터 줄을 세지 않게 편집마다 고친 곳만 다시 본다.
/// 줄은 \n 으로 나눈다(마지막 \n 뒤의 빈 줄도 한 줄 — 편집기에서 커서가 갈 수 있는 줄).
public struct LineIndex: Equatable, Sendable {
    /// 줄마다 시작 위치. 첫 줄은 늘 0.
    public private(set) var starts: [Int] = [0]

    public init() {}

    public init(_ text: NSString) {
        rebuild(text)
    }

    public var lineCount: Int { starts.count }

    public mutating func rebuild(_ text: NSString) {
        starts = [0]
        scan(text, from: 0, to: text.length, into: &starts)
    }

    /// 편집 뒤: range 는 새 글에서 바뀐 범위, delta 는 길이 변화(NSTextStorage editedRange·changeInLength 그대로)
    public mutating func edit(_ text: NSString, range: NSRange, delta: Int) {
        let location = range.location
        let oldEnd = location + range.length - delta // 옛 글에서 바뀐 범위 끝
        // 바뀐 범위 안의 줄바꿈으로 생긴 시작(location 다음 ~ oldEnd)은 빼고, 뒤는 delta 만큼 민다
        let first = firstIndex(after: location)
        var tail = first
        while tail < starts.count, starts[tail] <= oldEnd { tail += 1 }
        var inserted: [Int] = []
        scan(text, from: location, to: location + range.length, into: &inserted)
        let shifted = starts[tail...].map { $0 + delta }
        starts.replaceSubrange(first..., with: inserted + shifted)
    }

    /// location 보다 큰 첫 시작의 번호
    private func firstIndex(after location: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// location 이 들어 있는 줄(0부터)
    public func line(containing location: Int) -> Int {
        max(firstIndex(after: location) - 1, 0)
    }

    private func scan(_ text: NSString, from start: Int, to end: Int, into list: inout [Int]) {
        guard end > start else { return }
        let length = end - start
        let chunk = 16_384
        var buffer = [unichar](repeating: 0, count: min(length, chunk))
        var position = start
        while position < end {
            let count = min(chunk, end - position)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: count))
            }
            for i in 0..<count where buffer[i] == 10 { list.append(position + i + 1) }
            position += count
        }
    }
}
