import Darwin
import Foundation

public struct ProcInfo: Equatable {
    public var pid: pid_t
    public var ppid: pid_t
    /// 프로세스 시작 시각(epoch 초)
    public var startTime: Double
    /// 제어 터미널이 있는가(대화형 실행 여부 판단용)
    public var hasTTY: Bool
    /// 제어 터미널 장치 경로(예: /dev/ttys015). iTerm2 처럼 화면별 tty 를 알려주는 터미널과 짝지을 때 쓴다.
    public var tty: String? = nil
    /// 실행 파일 이름(커널이 아는 짧은 이름. 다른 사용자 프로세스도 읽힌다)
    public var command: String = ""
    /// 끝났지만 부모가 아직 거두지 않은 프로세스
    public var isZombie: Bool = false

    public init(pid: pid_t, ppid: pid_t, startTime: Double, hasTTY: Bool, tty: String? = nil,
                command: String = "", isZombie: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.startTime = startTime
        self.hasTTY = hasTTY
        self.tty = tty
        self.command = command
        self.isZombie = isZombie
    }
}

public enum ProcessUtil {
    public static func info(_ pid: pid_t) -> ProcInfo? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return procInfo(kp, tty: ttyName)
    }

    /// kinfo_proc 한 칸 → ProcInfo. tty 이름은 바깥에서 고른다(스냅샷은 장치별로 한 번만 찾는다).
    static func procInfo(_ kp: kinfo_proc, tty ttyOf: (dev_t) -> String?) -> ProcInfo {
        let tv = kp.kp_proc.p_starttime
        let hasTTY = (kp.kp_proc.p_flag & P_CONTROLT) != 0
        let tty: String? = hasTTY && kp.kp_eproc.e_tdev != -1 ? ttyOf(kp.kp_eproc.e_tdev) : nil
        let command = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return ProcInfo(
            pid: kp.kp_proc.p_pid,
            ppid: kp.kp_eproc.e_ppid,
            startTime: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000,
            hasTTY: hasTTY,
            tty: tty,
            command: command,
            isZombie: kp.kp_proc.p_stat == SZOMB
        )
    }

    /// devname 은 /dev 를 뒤져 한 번에 0.5ms 가량 든다. 장치 번호 ↔ 이름은 바뀌지 않으므로 찾은 것은 기억한다.
    static func ttyName(_ dev: dev_t) -> String? {
        ttyLock.lock(); defer { ttyLock.unlock() }
        if let known = ttyNames[dev] { return known }
        guard let name = devname(dev, S_IFCHR).map({ "/dev/" + String(cString: $0) }) else { return nil }
        ttyNames[dev] = name
        return name
    }
    private static let ttyLock = NSLock()
    nonisolated(unsafe) private static var ttyNames: [dev_t: String] = [:]

    /// 모든 프로세스를 sysctl(KERN_PROC_ALL) 한 번으로 읽는다(pid·ppid·이름·tty·시작 시각·좀비).
    /// 프로세스마다 info 를 부르는 것보다 훨씬 싸다. 실패하면 빈 스냅샷.
    public static func snapshot() -> ProcessSnapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { break }
            // 읽는 사이 프로세스가 늘 수 있어 여유를 둔다
            size += size / 8 + 32 * stride
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            var got = buf.count * stride
            let rc = buf.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &got, nil, 0) }
            if rc != 0 { if errno == ENOMEM { continue }; break }
            return ProcessSnapshot(buf.prefix(got / stride).map { procInfo($0, tty: ttyName) })
        }
        return ProcessSnapshot([])
    }

    /// argv. 같은 사용자의 프로세스만 읽을 수 있다.
    public static func arguments(_ pid: pid_t) -> [String]? {
        argumentsAndEnvironment(pid)?.0
    }

    /// 프로세스가 시작될 때 받은 환경변수(예: TERM_PROGRAM). 같은 사용자의 프로세스만 읽을 수 있다.
    public static func environment(_ pid: pid_t) -> [String: String]? {
        argumentsAndEnvironment(pid)?.1
    }

    /// argv 와 환경변수를 한 번에(KERN_PROCARGS2 한 번). 둘 다 필요하면 이것을 쓴다.
    public static func argumentsAndEnvironment(_ pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        // 형식: argc(Int32) · 실행 경로 · NUL 패딩 · argv[0..argc) · env...
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        var env: [String: String] = [:]
        while i < size && buf[i] != 0 {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            let entry = String(decoding: buf[start..<i], as: UTF8.self)
            if let eq = entry.firstIndex(of: "=") { env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...]) }
            i += 1
        }
        return (args, env)
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    public static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
    }

    /// 같은 PID 라도 시작 시각이 다르면 다른 프로세스(PID 재사용)로 본다.
    public static func isAlive(pid: pid_t, startedAt: Double) -> Bool {
        guard pid > 0, let p = info(pid), !p.isZombie else { return false }
        return abs(p.startTime - startedAt) < 0.001
    }

    /// 셸 말고 다른 프로그램(claude, vim, ssh, 서버 등)이 돌고 있는 tty 들.
    /// 여기 없는 tty 는 셸만 떠 있는 빈 화면이므로 명령을 입력해도 된다.
    public static func busyTTYs() -> Set<String> {
        var busy = Set<String>()
        for pid in allPids() {
            guard let p = info(pid), let tty = p.tty, !p.isZombie,
                  !idleCommands.contains(p.command.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
            else { continue }
            busy.insert(tty)
        }
        return busy
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
    /// 빈 화면에 떠 있어도 되는 것: 셸, 로그인, iTerm2 의 셸 실행기
    static let idleCommands: Set<String> = shells.union(["login", "ShellLauncher", "tcsh", "csh", "ksh", "nu"])

    /// hook 프로세스에서 위로 올라가며 claude 프로세스를 찾는다.
    /// 지금은 claude 가 hook 을 직접 띄우지만, 셸을 거쳐 띄우는 경우에도 셸은 건너뛴다.
    public static func findClaudeAncestor(from pid: pid_t = getppid()) -> pid_t {
        var current = pid
        for _ in 0..<3 {
            guard let args = arguments(current), let argv0 = args.first else { break }
            let name = (argv0 as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard shells.contains(name), let parent = info(current)?.ppid, parent > 1 else { break }
            current = parent
        }
        return current
    }
}
