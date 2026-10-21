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

    private func row(bars: Bool, staleWord: Bool) -> some View {
        HStack(alignment: .center, spacing: ui(8)) {
            Text(line.provider)
                .foregroundStyle(Color(TermAppearance.textPrimary).opacity(line.stale ? 0.55 : 0.85))
                .frame(minWidth: ui(38), alignment: .leading)
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

    private var color: NSColor {
        guard !stale else { return TermAppearance.textDim }
        switch cell.tier {
        case .normal: return TermAppearance.textDim
        case .warn: return TermAppearance.yellow
        case .critical: return TermAppearance.red
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: ui(4)) {
            Text(cell.label)
                .opacity(0.8)
            if bar {
                let width = ui(22)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(TermAppearance.textDim).opacity(0.22))
                    Capsule().fill(Color(color).opacity(stale ? 0.6 : 1))
                        .frame(width: width * min(1, max(0, (cell.percent ?? 0) / 100)))
                }
                .frame(width: width, height: ui(4))
            }
            Text(cell.text)
                .uiFont(10, bold: !stale && cell.tier == .critical)
                .foregroundStyle(Color(color))
                .frame(minWidth: ui(25), alignment: .leading)
        }
    }
}
