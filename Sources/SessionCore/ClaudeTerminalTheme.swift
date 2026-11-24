import Foundation

/// Claude Code 화면 색 하나: 고정 RGB 이거나 터미널 ANSI 16색 번호(0~15).
public enum ClaudeThemeColor: Equatable, Sendable {
    case rgb(UInt8, UInt8, UInt8)
    /// 터미널 테마의 16색 번호(black 0, red 1, green 2, yellow 3, blue 4, magenta 5, cyan 6, white 7, xxxBright = +8)
    case ansi(Int)
}

/// Claude Code 한 테마의 색(2.1.331 바이너리의 팔레트에서 추린 것)
public struct ClaudeThemePalette: Equatable, Sendable {
    public var text: ClaudeThemeColor
    public var inactive: ClaudeThemeColor
    public var success: ClaudeThemeColor
    public var error: ClaudeThemeColor
    public var permission: ClaudeThemeColor
    public var userMessageBackground: ClaudeThemeColor
}

/// Claude Code 의 테마 설정(.claude.json 의 "theme") → 팔레트. 모두 순수 함수.
public enum ClaudeTerminalTheme {
    public static let defaultName = "dark"

    private static func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ClaudeThemeColor { .rgb(r, g, b) }

    private static let dark = ClaudeThemePalette(
        text: c(255, 255, 255), inactive: c(153, 153, 153), success: c(78, 186, 101),
        error: c(255, 107, 128), permission: c(177, 185, 249), userMessageBackground: c(55, 55, 55))
    private static let light = ClaudeThemePalette(
        text: c(0, 0, 0), inactive: c(102, 102, 102), success: c(44, 122, 57),
        error: c(171, 43, 63), permission: c(87, 105, 247), userMessageBackground: c(240, 240, 240))
    private static let darkDaltonized = ClaudeThemePalette(
        text: c(255, 255, 255), inactive: c(153, 153, 153), success: c(51, 153, 255),
        error: c(255, 102, 102), permission: c(153, 204, 255), userMessageBackground: c(55, 55, 55))
    private static let lightDaltonized = ClaudeThemePalette(
        text: c(0, 0, 0), inactive: c(102, 102, 102), success: c(0, 102, 153),
        error: c(204, 0, 0), permission: c(51, 102, 255), userMessageBackground: c(220, 220, 220))
    private static let darkAnsi = ClaudeThemePalette(
        text: .ansi(15), inactive: .ansi(7), success: .ansi(10),
        error: .ansi(9), permission: .ansi(12), userMessageBackground: .ansi(8))
    private static let lightAnsi = ClaudeThemePalette(
        text: .ansi(0), inactive: .ansi(8), success: .ansi(2),
        error: .ansi(1), permission: .ansi(4), userMessageBackground: .ansi(7))

    /// 테마 이름 → 팔레트. "auto" 는 앱 모양(appDark)을 따르고, 모르는 이름·nil 은 "dark".
    public static func palette(named name: String?, appDark: Bool) -> ClaudeThemePalette {
        switch name {
        case "light": return light
        case "dark-daltonized": return darkDaltonized
        case "light-daltonized": return lightDaltonized
        case "dark-ansi": return darkAnsi
        case "light-ansi": return lightAnsi
        case "auto": return appDark ? dark : light
        default: return dark
        }
    }

    /// "ansi:whiteBright" 같은 이름 → 16색 번호. 모르면 nil.
    public static func ansiIndex(_ name: String) -> Int? {
        let base = name.hasPrefix("ansi:") ? String(name.dropFirst(5)) : name
        let bright = base.hasSuffix("Bright")
        let colorName = bright ? String(base.dropLast(6)) : base
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        guard let index = names.firstIndex(of: colorName) else { return nil }
        return index + (bright ? 8 : 0)
    }

    /// .claude.json 내용에서 "theme" 문자열. 없거나 읽을 수 없으면 nil.
    public static func themeName(inConfig data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let theme = object["theme"] as? String, !theme.isEmpty else { return nil }
        return theme
    }
}

/// .claude.json 의 테마 이름을 읽어 둔다: 파일 수정 시각이 그대로면 다시 읽지 않는다(이 파일은 클 수 있다).
/// 여러 스레드에서 불러도 안전하다.
public final class ClaudeThemeSetting: @unchecked Sendable {
    private let url: () -> URL
    private let lock = NSLock()
    private var cachedPath: String?
    private var cachedModified: Date?
    private var cachedName = ClaudeTerminalTheme.defaultName

    /// url: 읽을 때마다 부르는 설정 파일 위치(기본: Claude Code 와 같은 위치 — PlanUsageFiles.claudeConfig)
    public init(url: @escaping () -> URL = { PlanUsageFiles.claudeConfig() }) {
        self.url = url
    }

    /// 지금 설정의 테마 이름. 읽기 실패·파일 없음·"theme" 없음 → "dark".
    public func name() -> String {
        let file = url()
        // URL.resourceValues 는 URL 값마다 결과를 붙잡아 두므로 FileManager 로 본다
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if cachedPath == file.path, cachedModified == modified, modified != nil { return cachedName }
        let data = modified == nil ? nil : try? Data(contentsOf: file)
        cachedName = ClaudeTerminalTheme.themeName(inConfig: data) ?? ClaudeTerminalTheme.defaultName
        cachedPath = file.path
        cachedModified = modified
        return cachedName
    }
}
