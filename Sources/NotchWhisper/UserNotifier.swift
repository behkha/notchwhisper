import AppKit
import UserNotifications

/// System notifications for things that finish while the user is looking
/// elsewhere: a model that landed, a download that failed, an AI pass that
/// fell back to the original text. Banners show only while NotchWhisper is in
/// the background — in front, the notch and the status line already say it.
@MainActor final class UserNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UserNotifier()

    /// `UNUserNotificationCenter` aborts the process outside an app bundle
    /// (the `.build/debug` binary, every self-test flag), so every call is
    /// gated on running as a packaged `.app`.
    static let isAvailable: Bool =
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    private var authorizationRequested = false

    private override init() { super.init() }

    /// Installs the delegate. Called once at launch.
    func prepare() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, id: String = UUID().uuidString) {
        guard Self.isAvailable, Settings.shared.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        if authorizationRequested {
            deliver()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { deliver() }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            completionHandler(NSApp.isActive ? [] : [.banner, .list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            AppDelegate.shared?.showMainWindow()
            completionHandler()
        }
    }
}
