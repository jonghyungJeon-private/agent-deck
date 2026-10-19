import Foundation

/// 이 앱에서 새로 띄우는 claude·codex 의 기본 실행 옵션(설정 창 ⌘,). `term/launch.json` 에 저장한다.
/// 이미 돌고 있는 세션과 되살리는 세션(`--resume`)은 처음 실행한 인자를 그대로 쓴다(PaneRecipe).
public struct LaunchOptions: Codable, Equatable, Sendable {
    public var claude = ClaudeLaunch()
    public var codex = CodexLaunch()

    public init(claude: ClaudeLaunch = ClaudeLaunch(), codex: CodexLaunch = CodexLaunch()) {
        self.claude = claude
        self.codex = codex
    }

    enum CodingKeys: String, CodingKey { case claude, codex }

    // 빠진 칸·모르는 칸은 기본값으로(예전·다음 판 파일도 읽는다)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = (try? c.decodeIfPresent(ClaudeLaunch.self, forKey: .claude)) ?? ClaudeLaunch()
        codex = (try? c.decodeIfPresent(CodexLaunch.self, forKey: .codex)) ?? CodexLaunch()
    }

    /// 없거나 망가진 파일이면 기본값
    public static func load(from url: URL) -> LaunchOptions {
        guard let data = try? Data(contentsOf: url) else { return LaunchOptions() }
        return (try? JSONDecoder().decode(LaunchOptions.self, from: data)) ?? LaunchOptions()
    }

    public func data() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

/// claude 기본 옵션
public struct ClaudeLaunch: Codable, Equatable, Sendable {
    /// `--dangerously-skip-permissions`
    public var skipPermissions = false
    /// `--permission-mode <값>`. nil = 지정 안 함. 권한 확인 건너뛰기가 켜져 있으면 쓰지 않는다.
    public var permissionMode: String?
    /// `--model <값>`. nil·빈 값 = 지정 안 함
    public var model: String?
    /// 그 밖의 인자(셸처럼 따옴표로 묶는다)
    public var extraArgs = ""

    /// claude 2.1 의 `--permission-mode` 값(`claude --help`). "default" 는 없어 고르지 않는 것으로 둔다.
    public static let permissionModes = ["acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]
    /// 모델 별칭(`claude --help` 예시 + haiku). 전체 이름도 그대로 받는다.
    public static let modelSuggestions = ["opus", "sonnet", "haiku", "fable"]

    public init(skipPermissions: Bool = false, permissionMode: String? = nil, model: String? = nil, extraArgs: String = "") {
        self.skipPermissions = skipPermissions
        self.permissionMode = permissionMode
        self.model = model
        self.extraArgs = extraArgs
    }

    enum CodingKeys: String, CodingKey { case skipPermissions, permissionMode, model, extraArgs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipPermissions = (try? c.decodeIfPresent(Bool.self, forKey: .skipPermissions)) ?? false
        permissionMode = try? c.decodeIfPresent(String.self, forKey: .permissionMode)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        extraArgs = (try? c.decodeIfPresent(String.self, forKey: .extraArgs)) ?? ""
    }

    /// 실행 인자(맨 앞 `claude` 는 빼고)
    public var arguments: [String] {
        var args: [String] = []
        if skipPermissions { args.append("--dangerously-skip-permissions") }
        if !skipPermissions, let mode = permissionMode.nonBlank { args += ["--permission-mode", mode] }
        if let model = model.nonBlank { args += ["--model", model] }
        return args + ShellWords.split(extraArgs).words
    }

    /// 셸에 넣을 명령(미리보기와 같은 글)
    public var command: String { ShellWords.command(["claude"] + arguments) }
}

/// codex 기본 옵션
public struct CodexLaunch: Codable, Equatable, Sendable {
    /// `--dangerously-bypass-approvals-and-sandbox`(= `--yolo`). 켜면 승인·샌드박스 옵션은 쓰지 않는다.
    public var bypassApprovalsAndSandbox = false
    /// `--ask-for-approval <값>`
    public var approval: String?
    /// `--sandbox <값>`
    public var sandbox: String?
    /// `--model <값>`
    public var model: String?
    public var extraArgs = ""

    /// codex-cli 0.162 의 값(`codex --help` 로 확인 — untrusted·on-failure 는 받지 않는다)
    public static let approvals = ["on-request", "never"]
    public static let sandboxes = ["read-only", "workspace-write", "danger-full-access"]

    public init(bypassApprovalsAndSandbox: Bool = false, approval: String? = nil, sandbox: String? = nil,
                model: String? = nil, extraArgs: String = "") {
        self.bypassApprovalsAndSandbox = bypassApprovalsAndSandbox
        self.approval = approval
        self.sandbox = sandbox
        self.model = model
        self.extraArgs = extraArgs
    }

    enum CodingKeys: String, CodingKey { case bypassApprovalsAndSandbox, approval, sandbox, model, extraArgs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bypassApprovalsAndSandbox = (try? c.decodeIfPresent(Bool.self, forKey: .bypassApprovalsAndSandbox)) ?? false
        approval = try? c.decodeIfPresent(String.self, forKey: .approval)
        sandbox = try? c.decodeIfPresent(String.self, forKey: .sandbox)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        extraArgs = (try? c.decodeIfPresent(String.self, forKey: .extraArgs)) ?? ""
    }

    public var arguments: [String] {
        var args: [String] = []
        if bypassApprovalsAndSandbox {
            args.append("--dangerously-bypass-approvals-and-sandbox")
        } else {
            if let approval = approval.nonBlank { args += ["--ask-for-approval", approval] }
            if let sandbox = sandbox.nonBlank { args += ["--sandbox", sandbox] }
        }
        if let model = model.nonBlank { args += ["--model", model] }
        return args + ShellWords.split(extraArgs).words
    }

    public var command: String { ShellWords.command(["codex"] + arguments) }
}

/// 위험한 실행 옵션(권한·승인·샌드박스를 건너뜀) 알아보기 — 목록 줄·탭 풍선 도움말의 ⚠
public enum LaunchDanger {
    /// claude 인자(실행 파일 빼고)에서 위험한 것을 사람이 읽을 글로. 없으면 nil.
    public static func claude(_ args: [String]) -> String? {
        if args.contains("--dangerously-skip-permissions") { return "권한 확인 건너뜀 (--dangerously-skip-permissions)" }
        if value(of: "--permission-mode", in: args) == "bypassPermissions" { return "권한 확인 건너뜀 (--permission-mode bypassPermissions)" }
        return nil
    }

    /// codex 인자에서 위험한 것. 없으면 nil.
    public static func codex(_ args: [String]) -> String? {
        if args.contains("--yolo") || args.contains("--dangerously-bypass-approvals-and-sandbox") {
            return "승인·샌드박스 건너뜀 (yolo)"
        }
        if (value(of: "--sandbox", in: args) ?? value(of: "-s", in: args)) == "danger-full-access" {
            return "샌드박스 없음 (--sandbox danger-full-access)"
        }
        return nil
    }

    /// `--flag 값` 또는 `--flag=값`
    static func value(of flag: String, in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == flag, index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

/// 셸처럼 낱말 나누기·따옴표 붙이기(추가 인자 칸)
public enum ShellWords {
    public struct Result: Equatable {
        public var words: [String]
        /// 닫히지 않은 따옴표가 있었다(끝까지를 한 낱말로 쓴다)
        public var unterminated: Bool
    }

    /// 공백으로 나누고, '…' 는 그대로, "…" 안에서는 \" \\ \$ \` 만 풀고, 따옴표 밖 \ 는 다음 글자를 그대로 둔다.
    public static func split(_ text: String) -> Result {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in text {
            if escaped {
                if quote == "\"", !"\"\\$`".contains(ch) { current.append("\\") }
                current.append(ch)
                escaped = false
                continue
            }
            switch quote {
            case "'":
                if ch == "'" { quote = nil } else { current.append(ch) }
            case "\"":
                if ch == "\"" { quote = nil } else if ch == "\\" { escaped = true } else { current.append(ch) }
            default:
                if ch == " " || ch == "\t" || ch == "\n" {
                    if inWord { words.append(current); current = ""; inWord = false }
                } else if ch == "'" || ch == "\"" {
                    quote = ch; inWord = true
                } else if ch == "\\" {
                    escaped = true; inWord = true
                } else {
                    current.append(ch); inWord = true
                }
            }
        }
        if escaped { current.append("\\") }
        if inWord { words.append(current) }
        return Result(words: words, unterminated: quote != nil)
    }

    /// 낱말들을 셸 명령 한 줄로(필요한 것만 작은따옴표로)
    public static func command(_ words: [String]) -> String {
        words.map(PaneRecipe.shellQuote).joined(separator: " ")
    }
}

extension Optional where Wrapped == String {
    /// 앞뒤 공백을 지운 값, 비면 nil
    var nonBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
