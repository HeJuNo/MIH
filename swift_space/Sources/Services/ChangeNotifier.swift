import Foundation
import MyIceKit
import UserNotifications

/// Posts one local notification per change, threaded by event.
final class ChangeNotifier: Sendable {
    static let eventKeyUserInfo = "eventKey"
    /// Keep a burst (e.g. after a long offline period) from flooding the lock screen.
    static let maxPerRun = 50
    private let log: AppLog

    init(log: AppLog) { self.log = log }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Returns the number of notifications scheduled.
    func post(_ changes: [EventChange]) async -> Int {
        guard !changes.isEmpty else { return 0 }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            log(.warning, .notifications, "\(pluralized(changes.count, "change")) not delivered: permission denied (status \(status.rawValue))")
            return 0
        }

        let shown = changes.prefix(Self.maxPerRun)
        for change in shown {
            do {
                try await center.add(request(for: change))
                log(.debug, .notifications, "Delivered: \(ChangeFormatter.eventLabel(change)) – \(ChangeFormatter.text(for: change).headline)")
            } catch {
                log(.error, .notifications, "Could not create: \(error.localizedDescription)")
            }
        }
        let overflow = changes.count - shown.count
        if overflow > 0 {
            let content = UNMutableNotificationContent()
            content.title = "MyHockey Data"
            content.body = "\(overflow) weitere Änderungen. Öffne die App für Details."
            content.threadIdentifier = "summary"
            try? await center.add(UNNotificationRequest(identifier: "summary-\(UUID())", content: content, trigger: nil))
        }
        log(.info, .notifications, "\(shown.count) sent" + (overflow > 0 ? ", \(overflow) grouped" : ""))
        return shown.count + (overflow > 0 ? 1 : 0)
    }

    func request(for change: EventChange) -> UNNotificationRequest {
        let text = ChangeFormatter.text(for: change)
        let content = UNMutableNotificationContent()
        let label = ChangeFormatter.eventLabel(change)
        content.title = label.isEmpty ? "MyHockey Data" : label
        content.subtitle = text.headline
        content.body = [text.detail, eventLine(change)].filter { !$0.isEmpty }.joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = change.eventKey
        content.userInfo = [Self.eventKeyUserInfo: change.eventKey]
        content.relevanceScore = change.kind.category == .removed || change.kind.category == .schedule ? 1 : 0.5
        return UNNotificationRequest(identifier: change.id.uuidString, content: content, trigger: nil)
    }

    func sendTest() async {
        let content = UNMutableNotificationContent()
        content.title = "MyHockey Data"
        content.subtitle = "Test-Benachrichtigung"
        content.body = "So sehen Änderungen an deinen Spielen & Trainings aus."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "test-\(UUID())", content: content,
                                  trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
    }

    private func eventLine(_ change: EventChange) -> String {
        if case .added = change.kind { return "" }
        if case .removed = change.kind { return "" }
        guard let start = change.eventStart else { return "" }
        return "📅 " + start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(.de))
    }
}
