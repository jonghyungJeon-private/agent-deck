import Foundation
import TermLayout
import TermWire

/// `agentdeck` 가 앱에 보내는 요청(칸 배치·이름·그 칸으로 가기). 데이터 폴더 `term/requests/<ID>.json` 에 한 건씩 둔다.
///
/// 왜 파일인가: 앱이 꺼져 있어도 요청이 남았다가 앱이 켜질 때 처리되고(오래된 것은 버린다), 네트워크 포트가 없고,
/// 폴더는 사용자만 쓸 수 있어(0700) 다른 사용자가 보낼 수 없다. 분산 알림은 앱이 꺼져 있으면 사라지고 같은 사용자의
/// 어느 프로세스든 흉내 낼 수 있으며 순서·전달이 보장되지 않는다. 앱은 폴더를 감시하고(2초 목록 갱신에도 확인) 처리한 파일을 지운다.
public struct AppRequest: Codable, Equatable {
    public enum Action: String, Codable {
        /// 새로 만든 칸을 배치한다(anchor 옆) + 이름
        case place
        /// 그 칸으로 가고 앱을 앞으로 가져온다
        case focus
    }

    public enum Placement: String, Codable {
        /// 기본: anchor 의 오른쪽. 이미 오른쪽 줄이 있으면 그 줄 맨 아래로 쌓는다(하위 에이전트 칸과 같은 규칙).
        case stack
        case right, down
        /// anchor 없이 새 탭
        case tab
    }

    public var id: String
    public var action: Action
    public var pane: String
    /// 옆에 붙일 칸(부른 칸 또는 --of)
    public var anchor: String?
    public var placement: Placement?
    /// 칸 이름(--name). 앱의 이름 규칙에서 직접 바꾼 이름이 된다.
    public var name: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, action: Action, pane: String, anchor: String? = nil,
                placement: Placement? = nil, name: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.action = action
        self.pane = pane
        self.anchor = anchor
        self.placement = placement
        self.name = name
        self.createdAt = createdAt
    }
}

public struct AppRequestQueue {
    /// 이 시간이 지난 요청은 버린다(앱이 꺼져 있던 동안 쌓인 것이 한참 뒤에 되살아나지 않게)
    public static let ttl: TimeInterval = 60

    private let custom: URL?

    /// 데이터 위치를 옮겨도 따라가도록 쓸 때마다 계산한다(시험은 폴더를 직접 준다)
    public var dir: URL { custom ?? TermPaths.home.appendingPathComponent("requests", isDirectory: true) }

    public init(dir: URL? = nil) {
        custom = dir
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 폴더가 없으면 만든다(사용자만 접근)
    public func ensureDirectory() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    @discardableResult
    public func send(_ request: AppRequest) -> Bool {
        ensureDirectory()
        guard let data = try? Self.encoder.encode(request) else { return false }
        do {
            // 쓰는 중인 파일을 앱이 읽지 않게 숨김 이름으로 쓴 뒤 옮긴다
            let temp = dir.appendingPathComponent(".\(request.id).tmp")
            try data.write(to: temp)
            try FileManager.default.moveItem(at: temp, to: file(request.id))
            return true
        } catch {
            return false
        }
    }

    /// 요청 id 는 UUID 형식만 받는다(파일 이름이 되므로 "../" 같은 경로·이상한 글자를 막는다)
    public static func isValidId(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    private func file(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    /// 읽은 요청과 그 파일. 지울 때는 읽은 파일 그대로 지운다(요청 안의 id 로 파일 이름을 다시 만들지 않는다).
    public struct Pending: Equatable {
        public var url: URL
        public var request: AppRequest
    }

    /// 쓸 수 없는 파일(읽을 수 없음·오래됨·id 가 UUID 가 아님·파일 이름과 id 가 다름)은 파일만 지우고 무시한다.
    /// 남은 요청을 오래된 순으로 돌려준다.
    public func pending(now: Date = Date()) -> [Pending] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [Pending] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let request = try? Self.decoder.decode(AppRequest.self, from: data),
                  Self.isValidId(request.id), url.deletingPathExtension().lastPathComponent == request.id,
                  now.timeIntervalSince(request.createdAt) < Self.ttl
            else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            result.append(Pending(url: url, request: request))
        }
        return result.sorted { $0.request.createdAt < $1.request.createdAt }
    }

    /// 처리한 요청의 파일을 지운다
    public func remove(_ pending: Pending) {
        try? FileManager.default.removeItem(at: pending.url)
    }

    /// 보낸 쪽이 거둔다(칸을 만들지 못했을 때). id 가 UUID 가 아니면 아무것도 하지 않는다.
    public func discard(_ request: AppRequest) {
        guard Self.isValidId(request.id) else { return }
        try? FileManager.default.removeItem(at: file(request.id))
    }
}

/// 앱이 읽은 요청을 배치(Workspace)에 적용한다. 화면 없는 순수 부분이라 시험할 수 있다(앱은 이름 저장·앞으로 가져오기만 덧붙인다).
/// - place: 칸이 데몬 목록에 나타난 뒤에만(그 전엔 남겨 둔다 — CLI 는 요청을 칸 만들기보다 먼저 남기므로, 앱이 칸을 처음 보는 목록에서
///   바로 제자리에 붙고 새 탭으로 붙었다 옮겨지는 깜빡임이 없다). 이름은 `names` 로 돌려준다.
/// - focus: 그 칸이 있는 탭으로 가서 포커스한다(`activate`).
/// 처리한 요청은 `done` 에 담아 돌려준다(앱이 파일을 지운다). 같은 요청은 지우기가 실패해도 한 번만 적용한다.
public struct AppRequestApplier {
    public struct Result: Equatable {
        public var changed = false
        public var activate = false
        public var names: [(pane: String, name: String)] = []
        public var done: [AppRequestQueue.Pending] = []

        public static func == (a: Result, b: Result) -> Bool {
            a.changed == b.changed && a.activate == b.activate && a.done == b.done
                && a.names.map(\.pane) == b.names.map(\.pane) && a.names.map(\.name) == b.names.map(\.name)
        }
    }

    private var handled: [String: Date] = [:]

    public init() {}

    public mutating func apply(_ pending: [AppRequestQueue.Pending], to workspace: inout Workspace, live: Set<String>,
                               now: Date = Date()) -> Result {
        handled = handled.filter { now.timeIntervalSince($0.value) < AppRequestQueue.ttl * 2 }
        var result = Result()
        for item in pending {
            let request = item.request
            if handled[request.id] != nil { // 이미 적용했는데 파일이 남았다 — 다시 적용하지 말고 지우기만
                result.done.append(item)
                continue
            }
            switch request.action {
            case .place:
                guard live.contains(request.pane) else { continue } // 목록에 아직 안 나타났다(곧 온다)
                if let name = request.name { result.names.append((request.pane, name)) }
                if let anchor = request.anchor, request.placement != .tab {
                    let placement: NewPanePlacement = request.placement == .right ? .right : request.placement == .down ? .down : .stack
                    if workspace.place(newPane: request.pane, beside: anchor, placement) { result.changed = true }
                }
            case .focus:
                guard let index = workspace.tabIndex(containing: request.pane) else { continue }
                workspace.selected = workspace.tabs[index].id
                if workspace.tabs[index].focused != request.pane {
                    workspace.tabs[index].focused = request.pane
                    workspace.tabs[index].zoomed = false
                }
                result.changed = true
                result.activate = true
            }
            handled[request.id] = now
            result.done.append(item)
        }
        return result
    }
}
