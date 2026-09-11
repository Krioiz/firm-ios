import UIKit
import UserNotifications

/// Where a tapped notification should take you.
enum PushTarget {
    static let open = Notification.Name("firm.push.open")
}

// Real push. The device secret proves who we are; no cookie, no web view.
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
        DeviceAuth.post("https://getstubbie.com/dashboard/push/apns",
                        ["token": hex, "name": UIDevice.current.name,
                         "device_id": DeviceAuth.deviceId, "secret": DeviceAuth.secret]) { _, _ in }
    }

    func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] registration failed: \(error.localizedDescription)")
    }

    // Show it even while the app is open — otherwise a sale lands silently.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound, .list])
    }

    /// A tapped alert should land where the thing happened, not on whatever tab was last open.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["url"] as? String {
            NotificationCenter.default.post(name: PushTarget.open, object: nil,
                                            userInfo: ["url": raw])
        }
        h()
    }
}

/// The alerts carry paths like `/dashboard/app/?tab=business` or `?room=rm123`.
struct PushRoute {
    let tab: String?
    let room: String?
    init(_ raw: String) {
        let q = URLComponents(string: "https://x" + (raw.hasPrefix("/") ? raw : "/" + raw))?.queryItems ?? []
        tab = q.first { $0.name == "tab" }?.value
        room = q.first { $0.name == "room" }?.value
    }
}
