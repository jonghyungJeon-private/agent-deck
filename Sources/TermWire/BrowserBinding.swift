import CoreGraphics
import Foundation

/// 화면(에이전트) 하나 = 브라우저(abx 세션) 하나. 데몬은 화면 셸에 이 환경 변수를 넣고, 앱은 같은 값으로
/// 그 브라우저를 찾아 보여 준다. 화면 ID 로만 정해지므로 되살린 화면(같은 ID)은 같은 브라우저·같은 프로필을 쓴다.
/// 브라우저는 에이전트가 처음 `abx` 를 쓸 때 창 없이 뜬다(그 전에는 아무것도 띄우지 않는다).
public enum BrowserBinding {
    /// abx 세션 이름: "ad-" + 화면 ID 앞 12자리(48비트 — 화면 수백 개에서도 겹칠 일이 없고, 소켓 이름은 짧게)
    public static func sessionName(pane: String) -> String {
        "ad-" + String(pane.lowercased().filter(\.isHexDigit).prefix(12))
    }

    /// 가장 긴 소켓 이름(`<세션>.lock.sock`)
    static let longestSocketName = "ad-" + String(repeating: "0", count: 12) + ".lock.sock"
    /// 유닉스 소켓 경로 한도(sun_path 104바이트, 끝의 NUL 포함)
    static let socketPathLimit = 104

    /// 엔진·잠금 소켓이 있는 곳. 보통은 `term/abx`, 경로가 길어 소켓 한도를 넘으면(긴 계정 이름·AGENTDECK_TERM_HOME)
    /// 임시 폴더의 짧은 경로(`<TMPDIR>/agentdeck-abx-<term 경로 해시>`)를 쓴다.
    public static func socketDir(termDir: URL = TermPaths.home, temporary: String = NSTemporaryDirectory()) -> URL {
        let preferred = termDir.appendingPathComponent("abx", isDirectory: true)
        if fits(preferred) { return preferred }
        let short = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("agentdeck-abx-" + hash(termDir.path), isDirectory: true)
        return fits(short) ? short : URL(fileURLWithPath: "/tmp/agentdeck-abx-" + hash(termDir.path), isDirectory: true)
    }

    static func fits(_ dir: URL) -> Bool {
        (dir.path + "/" + longestSocketName).utf8.count < socketPathLimit
    }

    /// FNV-1a 64 앞 12자리(데몬 작업 이름과 같은 방식)
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return String(String(value, radix: 16).leftPadding(16).prefix(12))
    }

    /// abx 상태 파일(활성 탭·handoff·잠금 소유) — 소켓과 달리 길이 한도가 없어 늘 term 아래
    public static func stateDir(termDir: URL = TermPaths.home) -> URL {
        termDir.appendingPathComponent("abx/state", isDirectory: true)
    }

    /// 브라우저 프로필(로그인 유지)
    public static func profileDir(pane: String, termDir: URL = TermPaths.home) -> URL {
        profilesDir(termDir: termDir).appendingPathComponent(sessionName(pane: pane), isDirectory: true)
    }

    /// 로그인 템플릿: 있으면 새 프로필을 여기서 복사해 시작한다(abx `ABX_PROFILE_TEMPLATE`)
    public static func templateDir(termDir: URL = TermPaths.home) -> URL {
        profilesDir(termDir: termDir).appendingPathComponent("template", isDirectory: true)
    }

    static func profilesDir(termDir: URL) -> URL {
        termDir.appendingPathComponent("abx-profiles", isDirectory: true)
    }

    /// 화면 셸에 넣을 값. 브라우저는 창 없이(앱의 브라우저 화면으로 본다), 사람 입력은 잠근 채로 띄운다(배너 없이).
    /// 브라우저 실행 파일은 abx 가 처음 띄울 때 고른다: `browser`(AGENTDECK_BROWSER) → 앱이 받아 확인한 Chrome for Testing
    /// (`ABX_BROWSERS_DIR`, 이미 쓴 세션은 그 브라우저 그대로) → 엔진이 찾는 Chrome.
    /// `display`: 브라우저가 그릴 가상 화면(`ABX_BROWSER_ARGS` 의 `--screen-info`, abx 가 띄울 때 쓴다).
    public static func environment(pane: String, termDir: URL = TermPaths.home, browser: String? = explicitBrowser(),
                                   browsersDir: URL = BrowserBinding.browsersDir(),
                                   display: Display? = mainDisplay()) -> [String: String] {
        let socketDir = socketDir(termDir: termDir)
        var env = [
            "ABX_SESSION": sessionName(pane: pane),
            "ABX_SOCKET_DIR": socketDir.path,
            "ABX_STATE_DIR": stateDir(termDir: termDir).path,
            "ABX_PROFILE_DIR": profileDir(pane: pane, termDir: termDir).path,
            "ABX_PROFILE_TEMPLATE": templateDir(termDir: termDir).path,
            "ABX_BROWSERS_DIR": browsersDir.path,
            "ABX_HEADLESS": "1",
            "ABX_LOCK_INPUT": "1",
            // 잠금 상태는 브라우저 화면 머리 줄에 보인다. 페이지 위 배너(회색 덮개)는 화면 그림에 섞이므로 끈다
            "ABX_LOCK_BANNER": "0",
        ]
        if let browser { env["ABX_BROWSER"] = browser }
        if let display { env["ABX_BROWSER_ARGS"] = screenInfo(display) }
        return env
    }

    /// 화면 하나(픽셀 크기와 배율)
    public struct Display: Equatable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var scale: Double

        public init(pixelWidth: Int, pixelHeight: Int, scale: Double) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.scale = scale
        }
    }

    /// 이 Mac 의 주 화면. 창 없는 Chrome 은 기본으로 800×600·1배 화면에 그려서, 레티나 칸에 늘려 보이면 흐리고
    /// 사이트는 작은 화면으로 안다 — 일반 Chrome 처럼 실제 화면 크기·배율로 그리게 한다. 모르면 nil(Chrome 기본값).
    public static func mainDisplay() -> Display? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0, mode.height > 0 else { return nil }
        return Display(pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, scale: Double(mode.pixelWidth) / Double(mode.width))
    }

    /// Chrome `--screen-info={<픽셀 폭>x<픽셀 높이> devicePixelRatio=<배율>}` (논리 화면 = 픽셀 ÷ 배율)
    public static func screenInfo(_ display: Display) -> String {
        let scale = (display.scale * 100).rounded() / 100
        let ratio = scale == scale.rounded() ? String(Int(scale)) : String(scale)
        return "--screen-info={\(display.pixelWidth)x\(display.pixelHeight) devicePixelRatio=\(ratio)}"
    }

    /// 앱이 받아 두는 브라우저(Chrome for Testing) 폴더. abx 개발용 설치와 같은 곳을 함께 쓴다(시험용으로 AGENTDECK_BROWSERS_DIR).
    public static func browsersDir(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let dir = AgentDeckEnv.nonEmpty("BROWSERS_DIR", in: environment) {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return home.appendingPathComponent(".abx/browsers", isDirectory: true)
    }

    /// 브라우저를 고정할 때(시험·개발): `AGENTDECK_BROWSER`
    public static func explicitBrowser(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[AgentDeckEnv.name("BROWSER")].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    // MARK: - 화면에서 `abx` 명령

    /// 화면 셸 PATH 맨 앞에 두는 폴더. 안에 `abx` 하나(앱이 쓰는 abx 를 실행하는 작은 스크립트)만 둔다 —
    /// 앱 묶음의 Helpers 를 그대로 PATH 에 넣으면 엔진 실행 파일까지 보이고, 지정한 abx 의 이름이 abx 가 아닐 수도 있다.
    public static func binDir(termDir: URL = TermPaths.home) -> URL {
        termDir.appendingPathComponent("bin", isDirectory: true)
    }

    /// 화면에서 쓸 abx: `AGENTDECK_ABX` → 앱 묶음의 `Contents/Helpers/abx`(데몬·앱 실행 파일 기준). 없으면 nil(사용자 PATH 의 abx 를 그대로 쓴다).
    public static func bundledAbx(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  executable: URL? = Bundle.main.executableURL) -> URL? {
        let fm = FileManager.default
        if let path = environment[AgentDeckEnv.name("ABX")], fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        guard let executable else { return nil }
        let helper = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../Helpers/abx").standardizedFileURL
        return fm.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// `binDir/abx` 를 맞춘다(데몬이 뜰 때). abx 가 없으면 지운다. PATH 에 넣을 폴더를 돌려준다(없으면 nil).
    @discardableResult
    public static func installShim(abx: URL?, termDir: URL = TermPaths.home) -> URL? {
        let dir = binDir(termDir: termDir)
        let shim = dir.appendingPathComponent("abx")
        guard let abx else {
            try? FileManager.default.removeItem(at: shim)
            return nil
        }
        let quoted = "'" + abx.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\n# AgentDeck 이 화면에 주는 abx — 앱이 쓰는 abx 를 실행한다(데몬이 뜰 때 다시 쓴다)\nexec \(quoted) \"$@\"\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: shim, encoding: .utf8)) != script {
                try Data(script.utf8).write(to: shim, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            return dir
        } catch {
            return nil
        }
    }

    /// PATH 맨 앞에 폴더를 둔다(이미 있으면 앞으로 옮긴다)
    public static func prependPath(_ dir: URL, to path: String?) -> String {
        let rest = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0 != dir.path }
        return ([dir.path] + rest).joined(separator: ":")
    }
}

private extension String {
    func leftPadding(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
