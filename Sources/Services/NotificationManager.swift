import UserNotifications
import Foundation

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onRetry: ((UUID) -> Void)?
    var onOpenXcode: (() -> Void)?

    /// De-duplication: we only want one signed-out notification visible at a
    /// time, no matter how many projects were due when we noticed.
    private static let signedOutNotificationID = "signed-out-xcode"

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

    func sendSignedOutNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Not signed in to Xcode"
        content.body = "ReSign paused scheduled builds. Open Xcode → Settings → Accounts and sign in; builds resume automatically."
        content.sound = .default
        content.categoryIdentifier = "SIGNED_OUT"
        let request = UNNotificationRequest(
            identifier: Self.signedOutNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearSignedOutNotification() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.signedOutNotificationID])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.signedOutNotificationID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        if response.actionIdentifier == "OPEN_XCODE" {
            Task { @MainActor in self.onOpenXcode?() }
            return
        }

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
        let failureCategory = UNNotificationCategory(
            identifier: "BUILD_FAILURE",
            actions: [retryAction],
            intentIdentifiers: [],
            options: []
        )

        let openXcodeAction = UNNotificationAction(
            identifier: "OPEN_XCODE",
            title: "Open Xcode",
            options: [.foreground]
        )
        let signedOutCategory = UNNotificationCategory(
            identifier: "SIGNED_OUT",
            actions: [openXcodeAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([failureCategory, signedOutCategory])
    }
}
