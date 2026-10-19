public enum StableFileRead {
    public enum Failure: Error {
        case unstable
    }

    /// 읽는 사이 바뀐 파일은 다시 읽는다. 검증된 내용과 지문만 함께 돌려준다.
    public static func read<Value>(attempts: Int = 3, fingerprint: () -> FileFingerprint?,
                                    read: () throws -> Value) throws -> (value: Value, fingerprint: FileFingerprint) {
        for _ in 0..<max(1, attempts) {
            let before = fingerprint()
            let value: Value
            do {
                value = try read()
            } catch {
                if before == fingerprint() { throw error }
                continue
            }
            let after = fingerprint()
            if let before, before == after { return (value, before) }
        }
        throw Failure.unstable
    }
}
