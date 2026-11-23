import AppKit
import TermWire
import UserNotifications

/// macOS 알림. 누르면 그 화면으로 간다. `AGENTDECK_NO_NOTIFY=1` 이면 보내지 않는다(시험용).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// 알림을 눌렀을 때(화면 ID)
    var onOpen: ((String) -> Void)?
    /// 새 버전 알림을 눌렀을 때
    var onUpdate: (() -> Void)?
    private let enabled = !AgentDeckEnv.isOn("NO_NOTIFY")
    private var authorized = false

    func start() {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    func post(title: String, body: String, paneId: String, key: String) {
        guard enabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["pane": paneId]
        // 같은 화면의 알림은 새 것으로 바꿔 쌓이지 않게
        let request = UNNotificationRequest(identifier: "pane-\(paneId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        _ = key
    }

    /// 새 버전 알림(버전마다 한 번, UpdateNotifier 가 정한다). 앱을 켜자마자 올 수 있어 권한 답을 기다리지 않고
    /// 알림 설정을 직접 본다. 같은 ID 라 새 버전 알림은 하나만 남는다.
    func postUpdate(tag: String, current: String?) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "AgentDeck 새 버전 \(tag)"
        content.body = "지금 쓰는 버전은 v\(current ?? "?")입니다. 누르면 업데이트 방법을 봅니다."
        content.sound = .default
        content.userInfo = ["update": tag]
        let request = UNNotificationRequest(identifier: "update", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(request)
        }
    }

    /// 다시 볼 필요가 없어진 화면의 알림은 알림 센터에서 뺀다
    func clear(paneId: String) {
        guard enabled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["pane-\(paneId)"])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["update"] != nil {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.onUpdate?()
            }
        } else if let pane = response.notification.request.content.userInfo["pane"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.onOpen?(pane)
            }
        }
        completionHandler()
    }

    /// 앱을 보고 있어도 다른 화면 일이면 배너로 띄운다(보고 있는 화면이면 애초에 보내지 않는다)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
