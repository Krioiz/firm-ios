import UIKit
import UserNotifications
import WebKit

// Real push: the token from APNs goes to the server, which sends through Apple.
final class Push: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            if ok { DispatchQueue.main.async { app.registerForRemoteNotifications() } }
        }
        return true
    }
    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) {
        let hex = t.map { String(format: "%02x", $0) }.joined()
        Push.send(token: hex, tries: 0)
    }
    // the session cookie may not exist yet on first launch (the user has to sign in first)
    static func send(token: String, tries: Int) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            guard let s = cookies.first(where: { $0.name == "firm_session" }) else {
                if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 15) { send(token: token, tries: tries + 1) } }
                return
            }
            var req = URLRequest(url: URL(string: "https://getstubbie.com/dashboard/push/apns")!)
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("firm_session=\(s.value)", forHTTPHeaderField: "Cookie")
            req.setValue("FirmApp/2.0", forHTTPHeaderField: "User-Agent")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "name": UIDevice.current.name])
            URLSession.shared.dataTask(with: req).resume()
        }
    }
}
