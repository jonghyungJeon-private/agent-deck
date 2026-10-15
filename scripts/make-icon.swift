// 앱 아이콘(Resources/AppIcon.icns)을 그린다. 아이콘을 바꿀 때만 실행:
//   swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS 아이콘 격자: 824/1024 크기 둥근 사각형
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
               ending: NSColor(calibratedRed: 0.24, green: 0.21, blue: 0.19, alpha: 1))!.draw(in: path, angle: -90)
    // 프롬프트 기호 ›  와 커서 _
    let accent = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    let chevron = NSBezierPath()
    chevron.lineWidth = s * 0.075
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: s * 0.30, y: s * 0.64))
    chevron.line(to: NSPoint(x: s * 0.46, y: s * 0.50))
    chevron.line(to: NSPoint(x: s * 0.30, y: s * 0.36))
    accent.setStroke()
    chevron.stroke()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.52, y: s * 0.33, width: s * 0.20, height: s * 0.07),
                 xRadius: s * 0.02, yRadius: s * 0.02).fill()
    // 이어 열기(복원) 표시: 오른쪽 위 작은 원형 화살표
    let arc = NSBezierPath()
    arc.lineWidth = s * 0.035
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: NSPoint(x: s * 0.68, y: s * 0.66), radius: s * 0.08, startAngle: 120, endAngle: 400)
    NSColor(calibratedWhite: 0.93, alpha: 0.85).setStroke()
    arc.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
