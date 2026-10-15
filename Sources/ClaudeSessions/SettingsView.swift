import SessionCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SessionsModel
    @AppStorage(SettingsKey.terminal) private var terminal = "ghostty"
    @AppStorage(SettingsKey.commandTemplate) private var commandTemplate = CommandTemplate.defaultTemplate
    @AppStorage(SettingsKey.retentionDays) private var retentionDays = 14
    @AppStorage(SettingsKey.skipPermissions) private var skipPermissions = false
    @AppStorage(SettingsKey.showInDock) private var showInDock = true
    @AppStorage(SettingsKey.splitDirection) private var splitDirection = "right"
    @AppStorage(SettingsKey.reopenTarget) private var reopenTarget = "original"

    var body: some View {
        Form {
            Section("세션 열기") {
                Picker("터미널", selection: $terminal) {
                    ForEach(TerminalRegistry.all, id: \.id) { launcher in
                        Text(launcher.isInstalled ? launcher.displayName : "\(launcher.displayName) (설치 안 됨)")
                            .tag(launcher.id)
                    }
                }
                Picker("꺼진 세션 열 곳", selection: $reopenTarget) {
                    Text("세션이 돌던 터미널").tag("original")
                    Text("항상 위 터미널").tag("configured")
                }
                Text("배치(창·탭·분할)는 터미널마다 따로 기록합니다. '세션이 돌던 터미널'이면 Ghostty 세션은 Ghostty 에, iTerm2 세션은 iTerm2 에 다시 엽니다. 어느 터미널인지 모르는 세션은 위 터미널에 엽니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("실행 명령", text: $commandTemplate)
                    .font(.system(.body, design: .monospaced))
                Text("새 탭의 셸에 입력됩니다. {id} 세션 ID · {name} 세션 이름 · {cwd} 폴더")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("기본값으로") { commandTemplate = CommandTemplate.defaultTemplate }
                    .controlSize(.small)
                Toggle("권한 확인 건너뛰기 (--dangerously-skip-permissions)", isOn: $skipPermissions)
                Text("Claude 가 파일 수정·명령 실행을 묻지 않고 바로 합니다. 신뢰하는 프로젝트에서만 켜세요.\n실제 입력: \(preview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("분할 방향", selection: $splitDirection) {
                    Text("좌우 (오른쪽으로)").tag("right")
                    Text("상하 (아래로)").tag("down")
                }
                Text("모두 열기에서 새 창에 분할을 다시 만들 때 씁니다. Ghostty 가 되살린 창(window-save-state)에 열 때는 원래 방향 그대로입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("기록") {
                Stepper("꺼진 세션 보관: \(retentionDays)일", value: $retentionDays, in: 1...90)
                Button("꺼진 세션 기록 모두 지우기", role: .destructive) { model.forgetAllStopped() }
            }

            Section("Claude Code 연결") {
                LabeledContent("상태", value: statusText)
                HStack {
                    Button(model.hookStatus == .notInstalled ? "연결" : "다시 연결") { model.connectClaude() }
                    Button("연결 해제") { model.disconnectClaude() }
                        .disabled(model.hookStatus == .notInstalled)
                }
                Text("~/.claude/settings.json 에 SessionStart / SessionEnd hook 을 추가합니다. 바꾸기 전 같은 폴더에 settings.json.bak-claude-sessions-* 백업을 남깁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("앱") {
                Toggle("Dock 에 표시", isOn: $showInDock)
                    .onChange(of: showInDock) { _ in AppDelegate.shared?.applyDockPolicy() }
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0 }
                ))
            }

            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        // Form 은 스크롤 뷰라 정해진 높이가 없으면 NSHostingController 창이 높이 0 으로 접힌다.
        .frame(width: 520, height: 900)
        .onAppear { model.refreshHookStatus() }
    }

    private var preview: String {
        CommandTemplate.render(commandTemplate, sessionId: "SESSION-ID", name: "NAME", cwd: "/path",
                               skipPermissions: skipPermissions)
    }

    private var statusText: String {
        switch model.hookStatus {
        case .installed: return "연결됨"
        case .outdated: return "경로가 바뀜 — 다시 연결 필요"
        case .notInstalled: return "연결 안 됨"
        }
    }
}
