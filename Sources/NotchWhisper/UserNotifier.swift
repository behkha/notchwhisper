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

    /// What clicking a notification opens. Carried in `userInfo`.
    enum Action: String {
        case showMainWindow
        case showUpdates
    }
    /// Read from the nonisolated delegate callbacks, so not main-actor bound.
    private nonisolated static let actionKey = "action"

    private override init() { super.init() }

    /// Installs the delegate. Called once at launch.
    func prepare() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// - Parameter honorsNotificationSetting: false for notices with their own
    ///   switch (update availability), which the general toggle doesn't cover.
    func post(title: String, body: String, id: String = UUID().uuidString,
              action: Action = .showMainWindow, honorsNotificationSetting: Bool = true) {
        guard Self.isAvailable else { return }
        if honorsNotificationSetting, !Settings.shared.notificationsEnabled { return }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [Self.actionKey: action.rawValue]
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
        let action = notification.request.content.userInfo[Self.actionKey] as? String
        Task { @MainActor in
            // An update notice shows even in front: it comes from a background
            // check, so nothing on screen has said it yet.
            if action == Action.showUpdates.rawValue {
                completionHandler([.banner, .list])
            } else {
                completionHandler(NSApp.isActive ? [] : [.banner, .list])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.notification.request.content.userInfo[Self.actionKey] as? String
        Task { @MainActor in
            if action == Action.showUpdates.rawValue {
                AppDelegate.shared?.showUpdates()
            } else {
                AppDelegate.shared?.showMainWindow()
            }
            completionHandler()
        }
    }
}
