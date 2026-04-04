import UserNotifications
import Foundation

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onRetry: ((UUID) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        setupCategories()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendFailureNotification(project: ManagedProject, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Build Failed — \(project.name)"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = "BUILD_FAILURE"
        content.userInfo = ["projectID": project.id.uuidString]
        let request = UNNotificationRequest(
            identifier: "failure-\(project.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendSuccessNotification(project: ManagedProject) {
        let content = UNMutableNotificationContent()
        content.title = "\(project.name) installed"
        content.body = "Provisioning profile renewed successfully."
        let request = UNNotificationRequest(
            identifier: "success-\(project.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == "RETRY_BUILD",
              let idString = response.notification.request.content.userInfo["projectID"] as? String,
              let id = UUID(uuidString: idString) else { return }

        Task { @MainActor in
            self.onRetry?(id)
        }
    }

    // MARK: - Private

    private func setupCategories() {
        let retryAction = UNNotificationAction(
            identifier: "RETRY_BUILD",
            title: "Retry",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "BUILD_FAILURE",
            actions: [retryAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
