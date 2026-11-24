import Foundation
import TermLayout

/// `agentdeck new` 가 새 칸의 셸에 넣을 에이전트 실행 명령. 설정 창의 새 세션 기본 옵션(launch.json)에 칸마다의 모델·effort 를 덧씌운다 —
/// 오케스트레이터가 일의 무게에 맞게(구현은 가벼운 모델, 판단은 무거운 모델) 칸마다 고를 수 있게.
public enum NewPaneCommand {
    /// claude 의 `--effort` 값(`claude --help`)
    public static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// codex 의 `model_reasoning_effort` 값(codex config)
    public static let codexEfforts = ["minimal", "low", "medium", "high", "xhigh"]

    public struct Invalid: Error, Equatable { public var message: String }

    /// 셸에 넣을 명령. 셸 칸이면 nil. 모델·effort 가 맞지 않으면 Invalid.
    public static func command(kind: PaneKind, launch: LaunchOptions, model: String?, effort: String?, name: String?) throws -> String? {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let model {
            guard !model.isEmpty, !model.hasPrefix("-"), !model.contains(where: { $0.isWhitespace }) else {
                throw Invalid(message: "--model 값이 올바르지 않습니다: '\(model)'")
            }
        }
        switch kind {
        case .shell:
            if model != nil || effort != nil { throw Invalid(message: "--model·--effort 는 --claude·--codex 칸에만 쓸 수 있습니다") }
            return nil
        case .claude:
            var options = launch.claude
            if let model { options.model = model }
            var args = options.arguments
            if let effort {
                guard claudeEfforts.contains(effort) else {
                    throw Invalid(message: "claude 의 --effort 는 \(claudeEfforts.joined(separator: "·")) 중 하나입니다: '\(effort)'")
                }
                args = removing(["--effort"], from: args) + ["--effort", effort]
            }
            if let model { args = removing(["--model"], from: args) + ["--model", model] }
            return ShellWords.command(["claude"] + args + (name.map { ["--name", $0] } ?? []))
        case .codex:
            var options = launch.codex
            if let model { options.model = model }
            var args = options.arguments
            if let model { args = removingConfig("model", from: removing(["--model", "-m"], from: args)) + ["--model", model] }
            if let effort {
                guard codexEfforts.contains(effort) else {
                    throw Invalid(message: "codex 의 --effort 는 \(codexEfforts.joined(separator: "·")) 중 하나입니다: '\(effort)'")
                }
                args = removingConfig("model_reasoning_effort", from: args) + ["-c", "model_reasoning_effort=\"\(effort)\""]
            }
            return ShellWords.command(["codex"] + args)
        }
    }

    /// `--flag 값`·`--flag=값` 을 뺀다(기본 옵션의 추가 인자에 같은 것이 있으면 칸의 값이 이기게)
    /// 값이 빠진 플래그(`--effort --verbose`)는 플래그만 빼고 다음 낱말은 남긴다(`-` 로 시작하는 값은 없다고 본다 — 근사).
    /// 붙여 쓴 짧은 형식(`-mo3`·`-cmodel=…`)은 지우지 않는다.
    static func removing(_ flags: [String], from args: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if flags.contains(arg) {
                let hasValue = index + 1 < args.count && !args[index + 1].hasPrefix("-")
                index += hasValue ? 2 : 1
                continue
            }
            if !flags.contains(where: { arg.hasPrefix($0 + "=") }) { out.append(arg) }
            index += 1
        }
        return out
    }

    /// codex 의 `-c key=…`·`--config key=…`·`--config=key=…` 를 뺀다(그 key 만 — 칸의 값이 이기게)
    static func removingConfig(_ key: String, from args: [String]) -> [String] {
        func matches(_ value: String) -> Bool { value.hasPrefix(key + "=") }
        var out: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if (arg == "-c" || arg == "--config"), index + 1 < args.count, matches(args[index + 1]) { index += 2; continue }
            if arg.hasPrefix("--config="), matches(String(arg.dropFirst("--config=".count))) { index += 1; continue }
            out.append(arg)
            index += 1
        }
        return out
    }
}
