import AppKit
import SwiftTerm
import TermLayout
import TermWire

/// 작은 터미널 창의 임시 셸: 에이전트 세션마다 하나, 처음 열 때 만든다(작업 폴더 = 그 세션의 지금 폴더).
/// 데몬에는 "scratch-<세션 화면 ID>" 라는 보통 화면으로 있고(ScratchPane), 앱은 데몬 목록에서 떼어 내 세션으로 다루지 않는다.
/// 창을 닫아도 셸은 계속 돈다. 보이는 동안에만 터미널 뷰(PaneTerminal)를 만들고, 닫으면 뷰만 버린다(다시 열면 데몬의 지난 출력으로 되살림).
final class ScratchTerminals {
    private unowned let model: TermModel
    /// 지금 창에 붙은 터미널 뷰(주인 화면 ID → 뷰). 한 번에 하나.
    private(set) var views: [String: PaneTerminal] = [:]
    /// 만들라고/끝내라고 보냈지만 아직 목록에 반영되지 않은 임시 셸 기록
    private var tracker = ScratchShellTracker(timeout: TermModel.createTimeout)
    /// 연결이 끊겼다 다시 붙은 뒤 첫 목록을 받기 전(그 전의 목록·기록은 믿을 수 없다 — 이때는 뷰를 붙이지 않는다)
    private(set) var awaitingState = false
    /// 셸이 스스로 끝났을 때(주인 화면 ID) — 창을 닫고 다음에 새로 시작하게
    var onShellEnded: ((_ owner: String, _ hadFocus: Bool) -> Void)?

    init(model: TermModel) { self.model = model }

    /// 지금 창에 붙은 뷰
    var current: PaneTerminal? { views.values.first }
    var currentOwner: String? { views.keys.first }

    /// 키보드가 작은 터미널 뷰(또는 찾기 막대) 안에 있는지
    var hasFocus: Bool {
        // 창이 키일 때만(설정·별도 브라우저 창이 앞이면 뒤 작은 터미널에 메뉴 동작을 보내지 않는다)
        guard let current, let window = current.view.window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: current.surface)
    }

    /// 그 세션의 임시 셸이 데몬에 있거나 만드는 중인지
    func shellExists(owner: String) -> Bool {
        let id = ScratchPane.id(owner: owner)
        return tracker.exists(id, listed: model.scratchPanes[id] != nil, now: Date())
    }

    /// 그 세션의 터미널 뷰를 만들어 돌려준다(셸이 없으면 먼저 만든다). 이미 있으면 그대로.
    func acquire(owner: String, size: CGSize) -> PaneTerminal {
        if let view = views[owner] { return view }
        releaseAll() // 한 번에 하나만 붙어 있다
        let id = ScratchPane.id(owner: owner)
        if !shellExists(owner: owner) { create(owner: owner, size: size) }
        let terminal = PaneTerminal(id: id, client: model.client, frame: NSRect(origin: .zero, size: size))
        views[owner] = terminal
        terminal.attach()
        return terminal
    }

    private func create(owner: String, size: CGSize) {
        let id = ScratchPane.id(owner: owner)
        var cwd = model.row(owner)?.cwd ?? NSHomeDirectory()
        if !FileManager.default.fileExists(atPath: cwd) { cwd = NSHomeDirectory() }
        let probe = TerminalView(frame: NSRect(origin: .zero, size: size), font: TermAppearance.font).getTerminal()
        tracker.requestCreate(id, now: Date())
        model.client.create(CreateRequest(id: id, cwd: cwd, cols: max(probe.cols, 20), rows: max(probe.rows, 4), title: "작은 터미널"))
        model.client.list()
    }

    /// 뷰만 버린다(셸은 그대로)
    func release(owner: String) {
        views.removeValue(forKey: owner)?.detach()
    }

    func releaseAll() {
        for owner in Array(views.keys) { release(owner: owner) }
    }

    /// "끝내기": 셸을 끝내고 뷰를 버린다(다음에 열면 새 셸)
    func end(owner: String) {
        release(owner: owner)
        let id = ScratchPane.id(owner: owner)
        // 목록에 아직 없어도 보낸다: 만들기가 막 큐에 들어갔다면 목록보다 먼저 일어난 일이다(없는 ID 를 끝내라는 요청은 데몬이 무시한다)
        tracker.requestEnd(id, now: Date())
        model.client.kill(id)
    }

    func stateChanged() {
        awaitingState = false
        tracker.reconcile(listed: Set(model.scratchPanes.keys), now: Date())
    }

    /// 데몬 연결이 끊김: 붙어 있던 뷰를 버리고(세션 화면들처럼 다시 붙을 때 새로 만든다) 첫 목록이 올 때까지 기다린다
    func connectionLost() {
        releaseAll()
        tracker.reset()
        awaitingState = true
    }

    /// 글꼴 크기가 바뀜: 붙어 있는 터미널에 적용(칸 크기가 바뀌면 데몬에도 전해진다)
    func applyFont() {
        views.values.forEach { $0.applyFont() }
    }

    func receive(id: String, bytes: ArraySlice<UInt8>, replay: Bool) {
        views.values.first { $0.id == id }?.receive(bytes, replay: replay)
    }

    /// 셸이 끝남(exit·강제 종료): 창이 그 셸을 보고 있었으면 닫는다
    func exited(id: String) {
        // 끝내라고 한 옛 셸이 죽는 사이 다시 열어 보낸 만들기는 무시됐다 → 다시 만들라고 보낸다(창은 아래에서 닫히고, 다시 열면 새 셸)
        if tracker.exited(id), let owner = ScratchPane.owner(of: id) {
            create(owner: owner, size: views[owner]?.view.frame.size ?? CGSize(width: 640, height: 360))
        }
        guard let owner = ScratchPane.owner(of: id), let terminal = views[owner] else { return }
        let hadFocus = hasFocus // 떼기 전에(뗀 뒤에는 늘 false)
        views[owner] = nil
        terminal.detach()
        onShellEnded?(owner, hadFocus)
    }

    /// 닫아 둔 작은 터미널에서 명령이 돌고 있는지(앞에서 도는 것이 셸이 아님)
    func isBusy(owner: String) -> Bool {
        guard let name = model.scratchPanes[ScratchPane.id(owner: owner)]?.foreground?.split(separator: " ").first else { return false }
        return !PaneRow.shellNames.contains(String(name))
    }

    /// 시험 명령용 한 줄
    func debugSummary(owner: String?) -> String {
        guard let owner else { return "owner=- shell=no" }
        let id = ScratchPane.id(owner: owner)
        let info = model.scratchPanes[id]
        return "owner=\(owner.prefix(8)) pane=\(id.prefix(16)) shell=\(shellExists(owner: owner) ? "yes" : "no") "
            + "foreground=\(info?.foreground ?? "-") cwd=\(info?.cwd ?? "-") view=\(views[owner] != nil ? "yes" : "no") focus=\(hasFocus)"
    }
}
