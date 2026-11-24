import AppKit
import SessionCore
import TermWire

/// 설정 → 연결의 "에이전트끼리 일 시키기"(`agentdeck` 명령): 스킬(Claude Code) 넣기·빼기와 앱 밖 터미널용 링크.
/// 칸 안에서는 설치 없이 `agentdeck` 를 쓴다(데몬이 PATH 를 넣는다) — 여기는 그 명령을 에이전트에게 가르치는 스킬과, 앱 밖 터미널에서도 쓰는 링크다.
/// 사용자가 누를 때만 사용자 폴더(~/.claude/skills, ~/.local/bin)에 쓴다. 직접 둔 것은 덮지 않는다.
final class OrchestrationConnection: ObservableObject {
    static let skillName = "agentdeck-orchestrate"

    enum SkillState: Equatable {
        /// 앱 묶음에 스킬 파일이 없다(개발 빌드)
        case unavailable
        case missing
        /// 이 앱이 넣었고 같다
        case installed
        /// 이 앱이 넣었는데 앱의 것과 다르다(앱 업데이트)
        case outdated
        /// 직접 둔 스킬
        case userManaged
    }

    enum LinkState: Equatable {
        /// 앱 묶음에 `Helpers/agentdeck` 가 없다(개발 빌드)
        case unavailable
        case missing
        case installed
        case outdated
        case userManaged
    }

    @Published private(set) var skill: SkillState = .unavailable
    @Published private(set) var link: LinkState = .unavailable
    /// 마지막 동작 결과(설정 창 맨 위 알림에 합쳐 보인다)
    @Published var notice: String?

    /// 앱 묶음의 스킬 파일(`Contents/Resources/agentdeck-orchestrate/SKILL.md`)
    private var bundledSkill: String? {
        Bundle.main.resourceURL
            .flatMap { try? String(contentsOf: $0.appendingPathComponent("\(Self.skillName)/SKILL.md"), encoding: .utf8) }
    }

    private var skillInstaller: SkillInstaller {
        .claude(name: Self.skillName, markerNote: "AgentDeck이 넣은 스킬입니다. AgentDeck 설정 → 연결에서 뺄 수 있습니다.\n")
    }

    private var linkInstaller: CliLinkInstaller? {
        CliBinding.bundledHelper().map { CliLinkInstaller(target: $0) }
    }

    func refresh() {
        if let content = bundledSkill {
            switch skillInstaller.status(content: content) {
            case .notInstalled: skill = .missing
            case .installed: skill = .installed
            case .outdated: skill = .outdated
            case .userManaged: skill = .userManaged
            }
        } else {
            skill = .unavailable
        }
        switch linkInstaller?.status() {
        case nil: link = .unavailable
        case .notInstalled?: link = .missing
        case .installed?: link = .installed
        case .outdated?: link = .outdated
        case .userManaged?: link = .userManaged
        }
        // 이 앱이 넣은 스킬이 앱의 것과 다르면(앱 업데이트) 묻지 않고 맞춘다 — 에이전트가 읽는 사용법이 명령과 어긋나지 않게(abx 스킬과 같다)
        if skill == .outdated, let content = bundledSkill, (try? skillInstaller.install(content: content)) != nil {
            skill = .installed
        }
    }

    func connectSkill() {
        guard let content = bundledSkill else { notice = "이 빌드에는 스킬 파일이 없습니다(앱 묶음에서만 넣을 수 있습니다)."; return }
        do {
            try skillInstaller.install(content: content)
            notice = "\(Self.skillName) 스킬을 넣었습니다(~/.claude/skills). 새로 시작하는 claude 세션부터 적용됩니다."
        } catch {
            notice = "스킬을 넣지 못했습니다: \(error.localizedDescription)"
        }
        refresh()
    }

    func disconnectSkill() {
        do {
            notice = try skillInstaller.uninstall() ? "\(Self.skillName) 스킬을 뺐습니다." : "이 앱이 넣은 스킬이 없습니다(직접 둔 것은 건드리지 않습니다)."
        } catch {
            notice = "스킬을 빼지 못했습니다: \(error.localizedDescription)"
        }
        refresh()
    }

    func connectLink() {
        guard let installer = linkInstaller else { notice = "이 빌드에는 agentdeck 실행 파일이 없습니다(앱 묶음에서만 연결할 수 있습니다)."; return }
        do {
            try installer.install()
            let path = (installer.link.path as NSString).abbreviatingWithTildeInPath
            notice = "\(path) 를 만들었습니다. 터미널에서 agentdeck 를 쓰려면 ~/.local/bin 이 PATH 에 있어야 합니다."
        } catch {
            notice = "링크를 만들지 못했습니다: \(error.localizedDescription)"
        }
        refresh()
    }

    func disconnectLink() {
        do {
            notice = try linkInstaller?.uninstall() == true ? "agentdeck 링크를 지웠습니다." : "이 앱이 만든 링크가 없습니다(직접 둔 것은 건드리지 않습니다)."
        } catch {
            notice = "링크를 지우지 못했습니다: \(error.localizedDescription)"
        }
        refresh()
    }
}
