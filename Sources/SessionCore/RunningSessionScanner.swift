import Foundation

/// 앱(hook)을 설치하기 전부터 열려 있던 세션을 가져온다.
/// 실행 인자에 세션 ID 가 보이는 claude 프로세스(`--session-id`, `--resume`/`-r`)만 알아낼 수 있다.
public enum RunningSessionScanner {
    static let idFlags: Set<String> = ["--session-id", "--resume", "-r"]

    public static func sessionId(fromArguments args: [String]) -> String? {
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

    /// `claude -n <이름>` / `--name <이름>` 으로 준 세션 이름
    public static func nameArgument(_ args: [String]) -> String? {
        for (index, arg) in args.enumerated().dropFirst() {
            if (arg == "-n" || arg == "--name"), index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix("--name=") { return String(arg.dropFirst("--name=".count)) }
        }
        return nil
    }

    public struct ClaudeProcess {
        public var pid: pid_t
        public var args: [String]
        public var info: ProcInfo
        public var cwd: String

        public init(pid: pid_t, args: [String], info: ProcInfo, cwd: String) {
            self.pid = pid
            self.args = args
            self.info = info
            self.cwd = cwd
        }
    }

    /// 터미널에서 돌고 있는 claude 프로세스 중 실행 인자에 세션 ID 가 있는 것
    public static func systemProcesses() -> [ClaudeProcess] {
        ProcessUtil.allPids().compactMap { pid in
            guard let args = ProcessUtil.arguments(pid), sessionId(fromArguments: args) != nil,
                  let info = ProcessUtil.info(pid), info.hasTTY, let cwd = ProcessUtil.cwd(pid)
            else { return nil }
            return ClaudeProcess(pid: pid, args: args, info: info, cwd: cwd)
        }
    }

    /// 기록이 없는 실행 중 세션을 찾아 저장한다. 새로 가져온 개수를 돌려준다.
    /// 실행 인자의 세션 ID 는 그 뒤 세션 안에서 /resume 으로 바뀌었을 수 있으므로,
    /// hook 이 이미 기록 중인 프로세스는 건드리지 않는다(hook 기록이 항상 우선).
    @discardableResult
    public static func importRunning(into store: SessionStore, processes: [ClaudeProcess]? = nil) -> Int {
        let known = store.all()
        var imported = 0
        for process in processes ?? systemProcesses() {
            guard let id = sessionId(fromArguments: process.args),
                  !known.contains(where: { $0.pid == process.pid && abs($0.pidStartedAt - process.info.startTime) < 1 }),
                  store.load(id) == nil
            else { continue }
            var record = SessionRecord(
                sessionId: id, cwd: process.cwd, transcriptPath: TranscriptReader.locate(sessionId: id),
                pid: process.pid, pidStartedAt: process.info.startTime,
                startedAt: Date(timeIntervalSince1970: process.info.startTime),
                termProgram: ProcessUtil.environment(process.pid)?["TERM_PROGRAM"]
            )
            record.tty = process.info.tty
            if (try? store.save(record)) != nil { imported += 1 }
        }
        return imported
    }
}

/// 세션을 열 때 터미널에 입력할 명령. {id}, {name}, {cwd} 를 셸에 안전하게 바꿔 넣는다.
public enum CommandTemplate {
    public static let defaultTemplate = "claude --resume {id}"
    public static let skipPermissionsFlag = "--dangerously-skip-permissions"

    /// skipPermissions 면 명령 끝에 --dangerously-skip-permissions 를 붙인다(이미 있으면 그대로).
    /// claude 는 옵션 위치를 가리지 않고, claudec 처럼 나머지 인자를 claude 로 넘기는 래퍼에도 그대로 통한다.
    public static func render(_ template: String, sessionId: String, name: String, cwd: String,
                              skipPermissions: Bool = false) -> String {
        // 한 번에 훑으며 바꾼다(넣은 값 안의 "{cwd}" 같은 글자가 다시 바뀌지 않게)
        let values = ["{id}": shellQuote(sessionId), "{name}": shellQuote(name), "{cwd}": shellQuote(cwd)]
        var command = ""
        // 자리표시자를 따옴표로 감싸 두었으면 벗긴다("{name}" 안에서는 작은따옴표 보호가 통하지 않아 $(…) 가 실행될 수 있다)
        var unquoted = template
        for key in values.keys { for q in ["\"", "'"] { unquoted = unquoted.replacingOccurrences(of: q + key + q, with: key) } }
        var rest = Substring(unquoted)
        while let open = rest.firstIndex(of: "{") {
            command += rest[..<open]
            if let (key, value) = values.first(where: { rest[open...].hasPrefix($0.key) }) {
                command += value
                rest = rest[rest.index(open, offsetBy: key.count)...]
            } else {
                command.append("{")
                rest = rest[rest.index(after: open)...]
            }
        }
        command += rest
        if skipPermissions && !command.contains(skipPermissionsFlag) {
            command += " " + skipPermissionsFlag
        }
        return command
    }

    public static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./@:"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) && $0.isASCII }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
