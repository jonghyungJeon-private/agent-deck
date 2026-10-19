// 앱 아이콘(Resources/AppIcon.icns)을 그린다. 아이콘을 바꿀 때만 실행:
//   swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
// 어두운 바탕 위 흰 터미널 카드(› _ 와 초록 상태 점) 뒤로 보라 카드 두 장 — 여러 세션을 담은 덱
import AppKit

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let purple = rgb(0xa78bfa), purpleDeep = rgb(0x7c5cff)
let ink = rgb(0x14161c), paper = rgb(0xeef0f6)

// macOS 아이콘 격자: 824/1024 크기 둥근 사각형 바탕
func base(_ s: CGFloat, _ top: NSColor, _ bottom: NSColor) -> NSBezierPath {
    let inset = s * 100 / 1024
    let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let p = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(starting: bottom, ending: top)!.draw(in: p, angle: 90)
    return p
}

func rounded(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

// 그림자 흐림/오프셋/투명도는 모두 아이콘 크기(s)에 비례한다 (16px 에서도 같은 비율)
func shadow(_ s: CGFloat, _ blur: CGFloat = 0.03, _ y: CGFloat = -0.012, _ a: CGFloat = 0.45) {
    let sh = NSShadow(); sh.shadowBlurRadius = s * blur; sh.shadowOffset = NSSize(width: 0, height: s * y)
    sh.shadowColor = NSColor.black.withAlphaComponent(a); sh.set()
}

func dot(_ c: NSPoint, _ r: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
}

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    color.setFill(); rounded(NSRect(x: x, y: y, width: w, height: h), h / 2).fill()
}

// 보라 카드 두 장(뒤) + 흰 터미널 카드 한 장(앞): › 기호, 보라 커서 막대, 초록 상태 점
func icon(_ s: CGFloat) {
    _ = base(s, rgb(0x2a2e3a), rgb(0x14161d))
    let w = s * 0.50, h = s * 0.38, x = s * 0.20, y = s * 0.24
    for (k, c) in [(2, purple.withAlphaComponent(0.45)), (1, purple)] {
        let o = CGFloat(k) * s * 0.055
        shadow(s, 0.02, -0.006, 0.3)
        c.setFill(); rounded(NSRect(x: x + o, y: y + o, width: w, height: h), s * 0.05).fill()
        NSShadow().set()
    }
    let r = NSRect(x: x, y: y, width: w, height: h)
    shadow(s, 0.03, -0.01, 0.4)
    paper.setFill(); rounded(r, s * 0.05).fill()
    NSShadow().set()
    let chev = NSBezierPath(); chev.lineWidth = s * 0.042; chev.lineCapStyle = .round; chev.lineJoinStyle = .round
    chev.move(to: NSPoint(x: r.minX + w * 0.17, y: r.midY + h * 0.16))
    chev.line(to: NSPoint(x: r.minX + w * 0.31, y: r.midY - h * 0.02))
    chev.line(to: NSPoint(x: r.minX + w * 0.17, y: r.midY - h * 0.20))
    ink.setStroke(); chev.stroke()
    bar(r.minX + w * 0.40, r.midY - h * 0.20 - s * 0.018, w * 0.22, s * 0.036, purpleDeep)
    dot(NSPoint(x: r.maxX - w * 0.11, y: r.maxY - h * 0.15), s * 0.026, rgb(0x22c55e))
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon(s)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
