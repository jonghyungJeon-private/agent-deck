#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$WORK_ROOT"
mkdir -p "$VIDEO_ROOT/.work/source-backup"
cp Sources/AgentDeck/main.swift "$VIDEO_ROOT/.work/source-backup/main.swift"
cp Sources/AgentDeck/TerminalHostController.swift "$VIDEO_ROOT/.work/source-backup/TerminalHostController.swift"
cp Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift "$VIDEO_ROOT/.work/source-backup/MacTerminalView.swift"
cp Sources/AgentDeck/LaunchSettings.swift "$VIDEO_ROOT/.work/source-backup/LaunchSettings.swift"
restore() {
  cp "$VIDEO_ROOT/.work/source-backup/main.swift" Sources/AgentDeck/main.swift
  cp "$VIDEO_ROOT/.work/source-backup/TerminalHostController.swift" Sources/AgentDeck/TerminalHostController.swift
  cp "$VIDEO_ROOT/.work/source-backup/MacTerminalView.swift" Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift
  cp "$VIDEO_ROOT/.work/source-backup/LaunchSettings.swift" Sources/AgentDeck/LaunchSettings.swift
}
trap restore EXIT
python3 - <<'PY'
from pathlib import Path
p=Path('Sources/AgentDeck/main.swift')
s=p.read_text().replace('window.setFrameAutosaveName("AgentDeckMain")','if !AgentDeckEnv.isOn("DEBUG") { window.setFrameAutosaveName("AgentDeckMain") }')
p.write_text(s)
p=Path('Sources/AgentDeck/TerminalHostController.swift')
s=p.read_text()
a=s.index('    func snapshotTerminal(to url: URL) {')
b=s.index('    /// 화면 하나만 따로',a)
s=s[:a]+'''    func snapshotTerminal(to url: URL) {
        guard let content = view.window?.contentView else { return }
        let size = content.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: 2, y: 2)
        for terminal in terminals.values {
            let frame = terminal.view.convert(terminal.view.bounds, to: content)
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            context.clip(to: CGRect(origin: .zero, size: frame.size))
            context.setFillColor(TermAppearance.background.cgColor)
            context.fill(CGRect(origin: .zero, size: frame.size))
            terminal.view.videoRasterizeSnapshot()
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

'''+s[b:]
p.write_text(s)
p=Path('Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift')
s=p.read_text()
marker='    override public func draw (_ dirtyRect: NSRect) {'
helper='''    // Video-only offscreen snapshot: preserve actual buffer, attributes and fonts.
    public func videoRasterizeSnapshot() {
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let info = buildAttributedString(row: terminal.displayBuffer.yDisp + row,
                                             line: line, cols: terminal.cols)
            for segment in info.segments {
                let h = segment.attributedString.size().height
                segment.attributedString.draw(at: NSPoint(
                    x: CGFloat(segment.column) * cellDimension.width,
                    y: bounds.height - CGFloat(row + 1) * cellDimension.height
                        + (cellDimension.height - h) / 2))
            }
        }
    }

'''
assert marker in s
p.write_text(s.replace(marker, helper + marker))
p=Path('Sources/AgentDeck/LaunchSettings.swift')
s=p.read_text().replace('window.setFrameAutosaveName("AgentDeckSettings")','if !AgentDeckEnv.isOn("DEBUG") { window.setFrameAutosaveName("AgentDeckSettings") }')
s=s.replace('window?.orderFront(nil)', 'window?.orderBack(nil)')
p.write_text(s)
PY
export BUNDLE_ID=dev.agentdeck.video.20261019
scripts/build-term-proto.sh &
task_pid=$!
echo "$task_pid capture-build" >> "$VIDEO_ROOT/.work/pids.log"
wait "$task_pid"
