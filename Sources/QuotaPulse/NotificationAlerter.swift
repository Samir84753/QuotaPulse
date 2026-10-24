import QuotaCore
import UserNotifications

/// Sends a local macOS notification when a quota window crosses an alert threshold.
/// QuotaCore stays notification-framework free (`ThresholdAlertTracker` only decides *what*
/// crossed); this is the one place that talks to `UserNotifications`.
@MainActor
final class NotificationAlerter {
    static let shared = NotificationAlerter()

    private var permissionRequested = false

    func requestPermissionIfNeeded() async {
        guard !permissionRequested else { return }
        permissionRequested = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func send(_ crossings: [ThresholdAlertTracker.Crossing]) {
        for crossing in crossings {
            let content = UNMutableNotificationContent()
            content.title = "\(crossing.provider.displayName) quota at \(crossing.threshold)%"
            content.body = "\(crossing.windowLabel) is now \(Int(crossing.usedPercent.rounded()))% used."
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
