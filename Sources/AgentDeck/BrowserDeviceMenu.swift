import AppKit
import BrowserCore

/// 브라우저 머리 줄의 기기 버튼: 보고 있는 탭을 어떤 기기로 보는지(데스크톱·iPhone 16 Pro…)와 그 그림.
/// 누르면 기기 메뉴(DeviceMenu). 올리면 바탕이 밝아진다(FloatIconButton 과 같은 느낌).
final class DeviceButton: NSButton {
    private var hovering = false { didSet { refreshHoverColor() } }
    private var symbol = "desktopcomputer"
    /// 마지막으로 보인 상태(모양이 바뀌면 색이 값으로 굳은 그림을 다시 만든다)
    private var shown: (device: AbxStatus.Tab.Device?, busy: Bool) = (nil, false)

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerRadius = Space.xs + 2
        contentTintColor = TermAppearance.textSecondary
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        show(nil, busy: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 지금 기기(nil = 보통 창). busy: 바꾸는 중
    func show(_ device: AbxStatus.Tab.Device?, busy: Bool) {
        shown = (device, busy)
        symbol = Self.symbol(device)
        let name = busy ? "바꾸는 중…" : device.map { $0.name + ($0.landscape ? " · 가로" : "") } ?? "데스크톱"
        let color = device?.isMobile == true ? TermAppearance.textPrimary : TermAppearance.textSecondary
        let size = TermAppearance.scaled(TypeSize.secondary)
        // 이름 뒤 펼침 표시: 글자 ▾ 가 아니라 chevron.down 기호(색이 값으로 굳으니 모양이 바뀌면 다시 만든다)
        let chevron = NSTextAttachment()
        let side = TermAppearance.scaled(8)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .semibold).applying(.init(paletteColors: [color.resolved(effectiveAppearance)])))
        chevron.bounds = CGRect(x: 0, y: 0, width: side, height: side * 0.6)
        let title = NSMutableAttributedString(string: name + " ", attributes: [
            .font: TermAppearance.uiTextFont(size, weight: device == nil ? .regular : .semibold),
            .foregroundColor: color,
        ])
        title.append(NSAttributedString(attachment: chevron))
        attributedTitle = title
        contentTintColor = color
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: TermAppearance.scaled(TypeSize.row), weight: .medium))
        let sizeText = device.map { " · \(Int($0.width))×\(Int($0.height))" } ?? ""
        toolTip = "이 탭을 어떤 기기로 볼지 — 지금: \(name)\(sizeText)\n폰·태블릿 크기, 터치, 그 기기의 사용자 에이전트로 페이지를 다시 읽습니다(이 탭만)\nChrome으로 크기·사용자 에이전트·터치를 흉내 내는 것이라 진짜 Safari나 실제 기기는 아닙니다"
        setAccessibilityLabel(toolTip)
        isEnabled = !busy
    }

    func scaleChanged() { needsLayout = true; invalidateIntrinsicContentSize() }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + TermAppearance.scaled(Space.sm), height: max(base.height, FloatIconButton.side))
    }

    static func symbol(_ device: AbxStatus.Tab.Device?) -> String {
        guard let device else { return "desktopcomputer" }
        switch device.kind {
        case "phone": return device.landscape ? "iphone.landscape" : "iphone"
        case "tablet": return device.landscape ? "ipad.landscape" : "ipad"
        default: return "macbook"
        }
    }

    private func refreshHoverColor() { layer?.backgroundColor = hovering ? TermAppearance.chromeRaised.cg(in: self) : nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshHoverColor()
        show(shown.device, busy: shown.busy)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 누르면 할 일을 부르는 메뉴 항목(메뉴가 항목을 붙들고 있으니 항목 자신이 target)
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// 기기 메뉴: 데스크톱 · 최근에 고른 기기 · 브랜드(iPhone·iPad·Galaxy·Pixel·데스크톱 크기) ▸ 시리즈 ▸ 모델(크기와 함께) ·
/// 가로로 보기 · 직접 크기 입력. 지금 기기에 ✓, 그 기기가 든 브랜드·시리즈에 –.
/// locked: 바꿀 수 없는 까닭(AI 가 이 탭에서 작업 중) — 맨 위에 보이고 항목은 모두 꺼진다.
enum DeviceMenu {
    /// 고름: id(nil = 데스크톱), 가로인지
    typealias Pick = (_ id: String?, _ landscape: Bool) -> Void

    static func build(catalog: DeviceCatalog, current: AbxStatus.Tab.Device?, recents: [String], locked: String?,
                      pick: @escaping Pick, custom: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let enabled = locked == nil
        if let locked {
            menu.addItem(note(locked))
            menu.addItem(.separator())
        }
        let desktop = ActionItem("데스크톱 (보통 창)") { pick(nil, false) }
        desktop.image = icon("desktopcomputer")
        desktop.state = current == nil ? .on : .off
        desktop.isEnabled = enabled
        menu.addItem(desktop)

        let recent = recents.compactMap { id -> (String, DeviceCatalog.Device?)? in
            let device = catalog.device(id)
            return device != nil || id.contains("x") ? (id, device) : nil
        }
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("최근"))
            for (id, device) in recent {
                let item = deviceItem(id: id, name: device?.name ?? id, size: device?.sizeText, detail: device?.detail,
                                      current: current, enabled: enabled, pick: pick)
                item.image = icon(device.map { $0.kind == "tablet" ? "ipad" : $0.kind == "phone" ? "iphone" : "macbook" } ?? "rectangle.dashed")
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let path = current.flatMap { catalog.path($0.id) }
        for group in catalog.groups {
            let item = NSMenuItem(title: groupTitle(group.name), action: nil, keyEquivalent: "")
            item.image = icon(groupSymbol(group.name))
            item.state = path?.group == group.name ? .mixed : .off
            let sub = NSMenu()
            sub.autoenablesItems = false
            // 시리즈가 하나뿐이면 한 단계 줄인다
            if group.series.count == 1 {
                for d in group.series[0].devices { sub.addItem(deviceItem(d, current: current, enabled: enabled, pick: pick)) }
            } else {
                for series in group.series {
                    let seriesItem = NSMenuItem(title: seriesTitle(series.name), action: nil, keyEquivalent: "")
                    seriesItem.state = path?.series == series.name && path?.group == group.name ? .mixed : .off
                    let models = NSMenu()
                    models.autoenablesItems = false
                    for d in series.devices { models.addItem(deviceItem(d, current: current, enabled: enabled, pick: pick)) }
                    seriesItem.submenu = models
                    sub.addItem(seriesItem)
                }
            }
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let landscape = ActionItem("가로로 보기") {
            if let current { pick(current.id, !current.landscape) }
        }
        landscape.image = icon("rectangle.landscape.rotate")
        landscape.state = current?.landscape == true ? .on : .off
        landscape.isEnabled = enabled && current?.isMobile == true
        landscape.toolTip = current?.isMobile == true ? nil : "폰·태블릿을 고르면 쓸 수 있습니다"
        menu.addItem(landscape)
        let customItem = ActionItem("직접 크기 입력…") { custom() }
        customItem.image = icon("rectangle.dashed")
        customItem.isEnabled = enabled
        menu.addItem(customItem)
        return menu
    }

    private static func deviceItem(_ d: DeviceCatalog.Device, current: AbxStatus.Tab.Device?, enabled: Bool, pick: @escaping Pick) -> NSMenuItem {
        deviceItem(id: d.id, name: d.name, size: d.sizeText, detail: d.detail, current: current, enabled: enabled, pick: pick)
    }

    private static func deviceItem(id: String, name: String, size: String?, detail: String?, current: AbxStatus.Tab.Device?,
                                   enabled: Bool, pick: @escaping Pick) -> NSMenuItem {
        // 같은 기기를 다시 고르면 방향은 그대로(가로로 보던 것을 세로로 돌리지 않는다)
        let shownName = Self.sizeNotation(name)
        let item = ActionItem(shownName) { pick(id, current?.id == id ? current!.landscape : false) }
        let title = NSMutableAttributedString(string: shownName, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        // 이름에 크기가 이미 들어 있으면("Laptop 1280×800") 같은 크기를 한 번 더 적지 않는다
        let extra = [shownName.contains(size ?? "\u{0}") ? nil : size, detail].compactMap { $0 }.joined(separator: " · ")
        if !extra.isEmpty {
            title.append(NSAttributedString(string: "   " + extra, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        item.attributedTitle = title
        item.state = current?.id == id ? .on : .off
        item.isEnabled = enabled
        return item
    }

    /// 이름 속 "1280x800" 의 x 를 크기 표기와 같은 ×(곱하기)로: 한 메뉴에서 두 가지 글자가 섞이지 않게
    static func sizeNotation(_ name: String) -> String {
        name.replacingOccurrences(of: #"(?<=\d)x(?=\d)"#, with: "×", options: .regularExpression)
    }

    /// 구역 머리("최근"): macOS 14 부터는 시스템 구역 머리, 13 은 꺼진 작은 글 줄
    private static func sectionHeader(_ text: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: text) }
        return note(text)
    }

    private static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        item.isEnabled = false
        return item
    }

    private static func icon(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    private static func groupSymbol(_ name: String) -> String {
        switch name {
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Desktop": return "macbook"
        default: return "smartphone" // Galaxy·Pixel 등 안드로이드
        }
    }

    private static func groupTitle(_ name: String) -> String {
        switch name {
        case "Desktop": return "노트북·모니터 크기"
        case "Galaxy": return "Galaxy (삼성)"
        case "Pixel": return "Pixel (구글)"
        default: return name
        }
    }

    private static func seriesTitle(_ name: String) -> String {
        switch name {
        case "Laptop": return "노트북"
        case "Monitor": return "모니터"
        default: return name
        }
    }

    /// "직접 크기 입력…": 가로·세로(CSS 픽셀)·배율·모바일(터치·모바일 화면·안드로이드 사용자 에이전트). 취소면 nil.
    static func askCustomSize(window: NSWindow?, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "직접 크기 입력"
        alert.informativeText = "페이지가 보는 화면 크기(CSS 픽셀)입니다. 배율은 비워 두면 데스크톱은 이 화면 그대로, 모바일은 3배입니다.\nChrome으로 흉내 내는 것이라 진짜 Safari나 실제 기기는 아닙니다."
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        func field(_ placeholder: String, _ value: String) -> NSTextField {
            let f = NSTextField(string: value)
            f.placeholderString = placeholder
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            return f
        }
        let width = field("가로", "390"), height = field("세로", "844"), scale = field("배율", "")
        let mobile = NSButton(checkboxWithTitle: "모바일(터치·모바일 화면)", target: nil, action: nil)
        mobile.state = .on
        let row = NSStackView(views: [width, NSTextField(labelWithString: "×"), height, NSTextField(labelWithString: "@"), scale])
        row.spacing = 6
        let stack = NSStackView(views: [row, mobile])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = width
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let w = Int(width.stringValue), let h = Int(height.stringValue),
                  (50...5000).contains(w), (50...5000).contains(h) else { completion(nil); return }
            let s = Double(scale.stringValue.trimmingCharacters(in: .whitespaces))
            completion(DeviceCatalog.customId(width: w, height: h, scale: s, mobile: mobile.state == .on))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}
