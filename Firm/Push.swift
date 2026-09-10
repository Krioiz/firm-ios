import UIKit
import UserNotifications

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
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([.banner, .sound]) }
}
