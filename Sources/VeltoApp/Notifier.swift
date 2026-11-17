import Foundation
import UserNotifications
import VeltoCore

/// Native notifications for alerts that start firing. "New" means absent from the same source's previous
/// successful check, so a source coming back online, or a first check, never floods the screen.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notifyNewAlerts"
    /// Clicking a notification opens the menu on that source.
    var onOpen: ((UUID) -> Void)?
    /// "Snooze" buttons on a notification: source id, alert id, alert name, until.
    var onSnooze: ((UUID, String, String, Date) -> Void)?

    private nonisolated static let alertCategory = "alert"
    private nonisolated static let snoozeHour = "snooze-1h"
    private nonisolated static let snoozeTomorrow = "snooze-tomorrow"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// UNUserNotificationCenter needs a real app bundle; under `swift run` there is none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        center?.delegate = self
        center?.setNotificationCategories([UNNotificationCategory(identifier: Self.alertCategory, actions: [
            UNNotificationAction(identifier: Self.snoozeHour, title: "Snooze 1 Hour"),
            UNNotificationAction(identifier: Self.snoozeTomorrow, title: "Snooze Until Tomorrow"),
        ], intentIdentifiers: [])])
        if Self.isEnabled { requestAuthorization() }
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ new: [(source: SourceSnapshot, alert: Alert)]) {
        guard Self.isEnabled, let center, !new.isEmpty else { return }
        let content = UNMutableNotificationContent()
        // More than three at once is one event (a network blip, a deploy); one summary says that better.
        if new.count > 3 {
            content.title = "\(new.count) new alerts"
            content.body = Array(Set(new.map(\.source.name))).sorted().joined(separator: ", ")
            content.userInfo = ["source": new[0].source.id.uuidString]
            add(content, id: "batch-\(UUID().uuidString)", in: center)
            return
        }
        for (source, alert) in new {
            let content = UNMutableNotificationContent()
            content.title = alert.name
            content.subtitle = [source.name, alert.target].compactMap { $0 }.joined(separator: " · ")
            content.body = alert.summary ?? (alert.severity == .none ? "Firing" : "\(alert.severity.label) · firing")
            content.threadIdentifier = source.id.uuidString
            content.userInfo = ["source": source.id.uuidString, "alert": alert.id, "name": alert.name]
            content.categoryIdentifier = Self.alertCategory
            if alert.severity == .critical { content.sound = .default }
            add(content, id: "\(source.id.uuidString)-\(alert.id)", in: center)
        }
    }

    func postResolved(_ ended: [(source: SourceSnapshot, alert: Alert)]) {
        guard Self.isEnabled, let center, !ended.isEmpty else { return }
        if ended.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "\(ended.count) alerts resolved"
            content.body = Array(Set(ended.map(\.source.name))).sorted().joined(separator: ", ")
            content.userInfo = ["source": ended[0].source.id.uuidString]
            add(content, id: "resolved-batch-\(UUID().uuidString)", in: center)
            return
        }
        for (source, alert) in ended {
            let content = UNMutableNotificationContent()
            content.title = "Resolved: \(alert.name)"
            content.subtitle = [source.name, alert.target].compactMap { $0 }.joined(separator: " · ")
            content.body = "Stopped firing"
            content.threadIdentifier = source.id.uuidString
            content.userInfo = ["source": source.id.uuidString]
            add(content, id: "resolved-\(source.id.uuidString)-\(alert.id)", in: center)
        }
    }

    private func add(_ content: UNMutableNotificationContent, id: String, in center: UNUserNotificationCenter) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = (info["source"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let action = response.actionIdentifier
        if action == Self.snoozeHour || action == Self.snoozeTomorrow, let alertID = info["alert"] as? String, let name = info["name"] as? String {
            let presets = Snooze.presets()
            let until = action == Self.snoozeHour ? presets[0].until : presets[2].until
            await MainActor.run { onSnooze?(id, alertID, name, until) }
            return
        }
        await MainActor.run { onOpen?(id) }
    }
}
