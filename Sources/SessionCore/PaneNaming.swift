import Foundation
import TermWire

/// 직접 바꾼 이름과 첫 질문으로 지은 제목(`term/names.json`). 앱이 쓰고(SessionNames), `agentdeck` 명령은 읽기만 한다.
public struct SavedName: Codable, Equatable {
    public var title: String
    /// "user"(직접 바꿈) | "auto"(첫 질문으로 지음)
    public var source: String

    public init(title: String, source: String) {
        self.title = title
        self.source = source
    }
}

public enum SavedNames {
    public static var url: URL { TermPaths.home.appendingPathComponent("names.json") }

    public static func sessionKey(_ id: String) -> String { "session:\(id)" }
    public static func paneKey(_ id: String) -> String { "pane:\(id)" }

    public static func load(from url: URL = SavedNames.url) -> [String: SavedName] {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: SavedName].self, from: data)
        else { return [:] }
        return saved
    }

    public static func userTitle(_ key: String, in names: [String: SavedName]) -> String? {
        names[key].flatMap { $0.source == "user" ? $0.title : nil }
    }

    public static func autoTitle(session id: String, in names: [String: SavedName]) -> String? {
        names[sessionKey(id)].flatMap { $0.source == "auto" ? $0.title : nil }
    }
}

/// 화면 이름 정하기(탭·왼쪽 목록·분할 테두리·`agentdeck list` 가 모두 같은 이름을 쓴다). 순서:
/// 직접 바꾼 이름 → 사람이 붙인 대화 이름(`claude -n`·/rename) → Claude 가 붙인 제목 → 첫 질문으로 지은 제목(짓는 동안은 앞부분)
/// → 기계적으로 붙은 이름 → 폴더 이름.
public enum PaneNaming {
    /// claude 세션이 있는 화면. firstPrompt·autoTitle 은 앞 단계에서 못 정했을 때만 부른다(파일 읽기·제목 짓기 시작을 아끼려고).
    public static func claudeName(userTitle: String?, summary: TranscriptSummary, sessionCwd: String, folder: String,
                                  firstPrompt: () -> String?, autoTitle: (String) -> String?) -> String {
        if let userTitle { return userTitle }
        if let custom = summary.customTitle, !SessionNaming.isAutomatic(custom, cwd: sessionCwd) { return custom }
        if let ai = summary.aiTitle { return ai }
        if let prompt = firstPrompt() { return autoTitle(prompt) ?? SessionNaming.preview(of: prompt) }
        return summary.customTitle ?? folder
    }

    /// codex 세션이 있는 화면
    public static func codexName(userTitle: String?, paneUserTitle: String?, title: String, folder: String) -> String {
        userTitle ?? paneUserTitle ?? (title.isEmpty ? folder : SessionNaming.preview(of: title))
    }

    /// 이름을 정할 근거가 없을 때의 이름: 칸을 만들 때 붙인 이름(`agentdeck new --name` 이 데몬 칸 제목으로 준다 — 앱이 꺼져 있어도 보이게)이 있으면 그것,
    /// 아니면 폴더 이름. 데몬의 기본 제목(만들 때 폴더 이름)은 `cd` 로 폴더가 바뀌면 낡으므로 이름으로 치지 않는다.
    public static func fallbackName(_ reading: PaneReading) -> String {
        let folder = (reading.cwd as NSString).lastPathComponent
        let title = reading.pane.title.trimmingCharacters(in: .whitespaces)
        let defaultTitle = (reading.pane.cwd as NSString).lastPathComponent
        return title.isEmpty || title == defaultTitle ? folder : title
    }

    /// 명령줄의 싼 이름: names.json 에 저장된 이름(직접 바꾼 이름·첫 질문으로 지은 이름)과 codex·셸 이름만 쓰고 대화 파일은 읽지 않는다.
    /// claude 세션에 저장된 이름이 없으면 nil — 그때만 `displayName`(대화 파일을 읽는 비싼 길)이 필요하다.
    /// 자주 부르는 list·status·ask·wait·new 가 매번 모든 대화 파일(최대 16MB 씩)을 읽지 않게 하려는 것이다.
    public static func storedName(_ reading: PaneReading, names: [String: SavedName]) -> String? {
        let folder = fallbackName(reading)
        let paneUser = SavedNames.userTitle(SavedNames.paneKey(reading.pane.id), in: names)
        if let codex = reading.codexSession {
            return codexName(userTitle: SavedNames.userTitle("codex:" + codex.id, in: names), paneUserTitle: paneUser,
                             title: codex.title, folder: folder)
        }
        guard let session = reading.session else { return paneUser ?? folder }
        return SavedNames.userTitle(SavedNames.sessionKey(session.sessionId), in: names)
            ?? SavedNames.autoTitle(session: session.sessionId, in: names)
    }

    /// 읽기만 하는 쪽(명령줄)의 이름: names.json 과 대화 파일만 보고, 제목을 새로 짓지 않는다. 대화 파일을 읽으므로 싼 길(`storedName`)로 안 될 때만.
    public static func displayName(_ reading: PaneReading, names: [String: SavedName]) -> String {
        let folder = fallbackName(reading)
        let paneUser = SavedNames.userTitle(SavedNames.paneKey(reading.pane.id), in: names)
        if let codex = reading.codexSession {
            return codexName(userTitle: SavedNames.userTitle("codex:" + codex.id, in: names), paneUserTitle: paneUser,
                             title: codex.title, folder: folder)
        }
        guard let session = reading.session else { return paneUser ?? folder }
        let path = session.transcriptPath ?? TranscriptReader.locate(sessionId: session.sessionId)
        let summary = path.map { TranscriptReader.read(path: $0) } ?? TranscriptSummary()
        return claudeName(userTitle: SavedNames.userTitle(SavedNames.sessionKey(session.sessionId), in: names),
                          summary: summary, sessionCwd: session.cwd, folder: folder,
                          firstPrompt: { path.flatMap { TranscriptReader.firstPrompt(path: $0) } },
                          autoTitle: { _ in SavedNames.autoTitle(session: session.sessionId, in: names) })
    }
}

/// 화면에서 확인한 "완료"의 기록(`term/seen.json`). 앱이 쓰고(보고 있던 화면의 완료), 명령줄은 읽어 앱과 같은 "쉬는 중" 판단을 한다.
public enum SeenStore {
    public static var url: URL { TermPaths.home.appendingPathComponent("seen.json") }

    public static func load(from url: URL = SeenStore.url) -> [String: WorkStateRules.Seen] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: WorkStateRules.Seen].self, from: data)) ?? [:]
    }

    public static func save(_ seen: [String: WorkStateRules.Seen], to url: URL = SeenStore.url) {
        guard let data = try? JSONEncoder().encode(seen) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
