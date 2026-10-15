import Foundation

/// claude 실행 인자에서 세션 정보를 읽는다(세션 안에서 /resume 으로 바꿨으면 지금 세션과 다를 수 있다)
public enum ClaudeArguments {
    static let idFlags: Set<String> = ["--session-id", "--resume", "-r"]

    /// `--session-id`, `--resume`/`-r` 로 준 세션 ID. 출력만 하고 끝나는 `-p` 실행은 세지 않는다.
    public static func sessionId(_ args: [String]) -> String? {
        guard let argv0 = args.first, (argv0 as NSString).lastPathComponent == "claude" else { return nil }
        if args.dropFirst().contains(where: { $0 == "-p" || $0 == "--print" || $0.hasPrefix("--print=") }) { return nil }
        for (index, arg) in args.enumerated() {
            if idFlags.contains(arg), index + 1 < args.count, SessionStore.isValidId(args[index + 1]) {
                return args[index + 1]
            }
            for flag in idFlags where flag.hasPrefix("--") && arg.hasPrefix(flag + "=") {
                let value = String(arg.dropFirst(flag.count + 1))
                if SessionStore.isValidId(value) { return value }
            }
        }
        return nil
    }
}
