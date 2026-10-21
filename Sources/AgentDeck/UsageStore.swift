import Foundation
import SessionCore

/// 상태 줄의 Claude·Codex 요금제 사용량(5시간·주간). 새 타이머 없이 2초 목록 갱신(TermModel.tick)에 얹고,
/// 수정 시각·크기가 바뀐 파일만 다시 읽는다. 파일은 읽기만 한다(토큰·API 없음).
final class UsageStore: ObservableObject {
    /// 늘 보인다(정보가 없으면 "정보 없음")
    @Published private(set) var claude: UsageLine?
    /// 최근 Codex 기록이 없으면 nil(줄을 숨긴다)
    @Published private(set) var codex: UsageLine?

    static let claudeMissingHelp = """
        Claude 사용량 기록을 찾지 못했습니다.
        Claude Code 는 사용량 한도를 상태 줄(status line)·플러그인에만 알려 줍니다.
        한도를 파일로 남기는 상태 줄·플러그인(예: cc-dash → ~/.claude/cc-dash/usage.json)이 있으면 그 값을,
        없으면 Claude Code 에서 /usage 를 열었을 때 남는 캐시(~/.claude.json)를 보여 줍니다.
        """

    private let queue = DispatchQueue(label: "AgentDeck.usage", qos: .utility)
    private var busy = false // 메인 스레드에서만
    // 아래는 queue 에서만
    private struct Stamp: Equatable { var modified: Date; var size: UInt64 }
    private var cache: [String: (stamp: Stamp, usage: PlanUsage?)] = [:]
    private var lastCodexFile: URL?

    func refresh() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            var seen = Set<String>()
            let claude = UsageSummary.line(provider: "Claude", usage: self.readClaude(&seen), now: now,
                                           missingHelp: Self.claudeMissingHelp)
            let codex = self.readCodex(now: now, seen: &seen).map {
                UsageSummary.line(provider: "Codex", usage: $0, now: now, missingHelp: "")
            }
            self.cache = self.cache.filter { seen.contains($0.key) }
            DispatchQueue.main.async {
                self.busy = false
                if self.claude != claude { self.claude = claude }
                if self.codex != codex { self.codex = codex }
            }
        }
    }

    private func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Stamp(modified: modified, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    /// 바뀌지 않은 파일은 지난 결과를 그대로 쓴다
    private func cached(_ url: URL, stamp: Stamp, seen: inout Set<String>, read: () -> PlanUsage?) -> PlanUsage? {
        seen.insert(url.path)
        if let hit = cache[url.path], hit.stamp == stamp { return hit.usage }
        let usage = read()
        cache[url.path] = (stamp, usage)
        return usage
    }

    /// cc-dash 기록과 Claude Code 의 /usage 캐시 중 더 최근 것
    private func readClaude(_ seen: inout Set<String>) -> PlanUsage? {
        var found: [PlanUsage] = []
        for url in PlanUsageFiles.ccDash() {
            guard let stamp = stamp(url) else { continue }
            if let usage = cached(url, stamp: stamp, seen: &seen, read: {
                (try? Data(contentsOf: url)).flatMap(PlanUsageParser.ccDash)
            }) { found.append(usage) }
        }
        let config = PlanUsageFiles.claudeConfig()
        if let stamp = stamp(config), let usage = cached(config, stamp: stamp, seen: &seen, read: {
            (try? Data(contentsOf: config)).flatMap { PlanUsageParser.claudeCache(configFile: $0) }
        }) { found.append(usage) }
        return found.max { $0.recordedAt < $1.recordedAt }
    }

    /// 오늘·어제 폴더의 rollout(과 지난번에 찾은 파일)을 최근 수정 순으로. 수정 시각이 이미 찾은 기록보다 이르면 멈춘다.
    private func readCodex(now: Date, seen: inout Set<String>) -> PlanUsage? {
        let fm = FileManager.default
        var files = PlanUsageFiles.codexDayFolders(now: now).flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
                .map { dir.appendingPathComponent($0) }
        }
        if let last = lastCodexFile, !files.contains(last) { files.append(last) }
        let stamped = files.compactMap { url in stamp(url).map { (url, $0) } }.sorted { $0.1.modified > $1.1.modified }
        var best: (url: URL, usage: PlanUsage)?
        for (url, stamp) in stamped.prefix(12) {
            if let best, stamp.modified < best.usage.recordedAt { break }
            let usage = cached(url, stamp: stamp, seen: &seen) {
                // 끝 64KB 에 없으면(긴 출력 줄) 1MB 까지 한 번 더
                let near = PlanUsageFiles.tail(url, bytes: 64 << 10)
                    .flatMap { PlanUsageParser.codexRateLimits(tail: $0, fallbackDate: stamp.modified) }
                guard near == nil, stamp.size > 64 << 10 else { return near }
                return PlanUsageFiles.tail(url, bytes: 1 << 20)
                    .flatMap { PlanUsageParser.codexRateLimits(tail: $0, fallbackDate: stamp.modified) }
            }
            if let usage, usage.recordedAt > best?.usage.recordedAt ?? .distantPast { best = (url, usage) }
        }
        if let best { lastCodexFile = best.url }
        return best?.usage
    }
}
