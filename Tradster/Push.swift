import UIKit
import UserNotifications

/// A tapped notification carries the conversation it is about.
enum PushTarget {
    static let open = Notification.Name("tradster.push.open")
}

// Real push, from Tradster itself. The phone registers its APNs token with the server, proving
// who it is with the same Keychain secret it uses for sessions. The server pushes when the book
// acts (a basket opened, a stop hit, a new listing) and when the morning brief is ready.
final class Push: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            if ok { DispatchQueue.main.async { app.registerForRemoteNotifications() } }
        }
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) {
        let hex = t.map { String(format: "%02x", $0) }.joined()
        DeviceAuth.post("https://getstubbie.com/dashboard/book/push/register",
                        ["token": hex, "name": UIDevice.current.name,
                         "device_id": DeviceAuth.deviceId, "secret": DeviceAuth.secret]) { _, _ in }
    }

    func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] registration failed: \(error.localizedDescription)")
    }

    // Show it even while the app is open.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let conv = info["conv"] as? String, !conv.isEmpty {
            NotificationCenter.default.post(name: PushTarget.open, object: nil, userInfo: ["conv": conv])
        }
        h()
    }
}
