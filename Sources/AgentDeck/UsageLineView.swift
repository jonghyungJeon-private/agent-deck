import SessionCore
import SwiftUI

/// 상태 줄의 요금제 사용량 한 줄: "Claude  5h ▬▬─ 36%  7d ▬▬▬ 61%". 풍선 도움말에 초기화 시각·기록 시각.
/// 폭이 모자라면(⌘+ 로 키웠을 때) 막대를 빼고, 그래도 모자라면 "오래됨" 글을 뺀다 — 숫자는 자르지 않는다.
struct UsageLineView: View {
    let line: UsageLine
    @Environment(\.uiScale) private var ui

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(bars: true, staleWord: true)
            row(bars: false, staleWord: true)
            row(bars: false, staleWord: false)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .help(line.help)
    }

    private var kind: SessionKind { line.provider == "Codex" ? .codex : .claude }

    private func row(bars: Bool, staleWord: Bool) -> some View {
        HStack(alignment: .center, spacing: ui(8)) {
            // 범례: 종류 아이콘 + 이름을 종류 색으로(✻ Claude · ‹› Codex) — 세션 줄·탭의 종류 색과 같은 뜻
            HStack(spacing: ui(Space.xs)) {
                SessionKindIcon(kind: kind, size: ui(TypeSize.caption), weight: .semibold)
                    .frame(width: ui(14), alignment: .leading)
                Text(line.provider)
            }
            .foregroundStyle(Color(kind.color))
            .frame(minWidth: ui(58), alignment: .leading)
            if line.cells.isEmpty {
                Text("사용량 정보 없음")
            } else {
                ForEach(line.cells, id: \.label) { cell in
                    UsageCellView(cell: cell, bar: bars, stale: line.stale)
                }
            }
            if line.stale && staleWord {
                Text("오래됨")
            }
        }
        .fixedSize()
    }
}

private struct UsageCellView: View {
    let cell: UsageCell
    let bar: Bool
    let stale: Bool
    @Environment(\.uiScale) private var ui

    /// 막대·숫자 색: 평소 중립, 80% 이상 경고(호박색), 90% 이상(critical)은 빨강 — 오래된 값은 늘 중립
    private var level: Level {
        guard !stale, let percent = cell.percent else { return .normal }
        return cell.tier == .critical ? .critical : percent >= 80 ? .warn : .normal
    }

    private enum Level { case normal, warn, critical }

    private var barColor: NSColor {
        switch level {
        case .normal: return TermAppearance.textSecondary
        case .warn: return TermAppearance.warning
        case .critical: return TermAppearance.statusAttention
        }
    }

    private var textColor: NSColor {
        switch level {
        case .normal: return TermAppearance.textSecondary
        case .warn: return TermAppearance.warnText
        case .critical: return TermAppearance.statusAttention
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: ui(4)) {
            Text(cell.label).foregroundStyle(Color(TermAppearance.textSecondary))
            if bar {
                let width = ui(22)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(TermAppearance.textDim).opacity(0.22))
                    Capsule().fill(Color(barColor).opacity(stale ? 0.6 : 1))
                        .frame(width: width * min(1, max(0, (cell.percent ?? 0) / 100)))
                        .animation(Motion.ease(), value: cell.percent)
                }
                .frame(width: width, height: ui(4))
            }
            Text(cell.text)
                .uiFont(10, bold: level == .critical)
                .foregroundStyle(Color(textColor))
                .frame(minWidth: ui(25), alignment: .leading)
        }
    }
}
