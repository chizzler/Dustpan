import DustpanCore
import UserNotifications

/// Reminders as notifications, with Snooze 10 min and Dismiss. Clicking one opens its task.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "reminder"
    private static let snooze = "snooze"
    private static let dismiss = "dismiss"

    private let center = UNUserNotificationCenter.current()
    /// Acts on the buttons and clicks.
    weak var model: AppModel?

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [UNNotificationAction(identifier: Self.snooze, title: "Snooze 10 min"),
                      UNNotificationAction(identifier: Self.dismiss, title: "Dismiss")],
            intentIdentifiers: [])])
    }

    /// False when notifications are turned off for Dustpan.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func show(_ alert: Alert, body: String) {
        let content = UNMutableNotificationContent()
        content.title = alert.task["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Reminder"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["reminder": alert.reminder.id, "task": alert.task.id]
        center.add(UNNotificationRequest(identifier: Self.identifier(alert.reminder.id), content: content, trigger: nil))
    }

    func withdraw(_ reminderIds: [String]) {
        guard !reminderIds.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: reminderIds.map(Self.identifier))
    }

    private static func identifier(_ reminderId: String) -> String { "reminder-\(reminderId)" }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let reminderId = info["reminder"] as? String, let taskId = info["task"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.snooze: model?.snooze(reminderId)
            case Self.dismiss: model?.dismiss(reminderId)
            case UNNotificationDefaultActionIdentifier: model?.open(taskId)
            default: break
            }
        }
    }

    /// Shown while Dustpan is in front, too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
