import Foundation
import UserNotifications
import WebKit
import BackgroundTasks
import UIKit

// Notifications without APNs: the app reads the firm's alert log itself and posts each
// new alert as a local notification. Foreground: polled every 30s. Background: iOS wakes
// us on its own schedule via BGAppRefresh — minutes to hours, iOS's call, not ours.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()
    static let taskId = "com.getstubbie.firm.refresh"
    private let seenKey = "alerts.lastSeen"
    private var timer: Timer?

    func start() {
        let c = UNUserNotificationCenter.current(); c.delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Alerts.taskId, using: nil) { task in
            self.refresh { task.setTaskCompleted(success: true); self.schedule() }
        }
        schedule()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.refresh { } }
        refresh { }
    }
    func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: Alerts.taskId); r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    // the web view holds the session cookie; borrow it for the fetch
    func refresh(_ done: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            guard let s = cookies.first(where: { $0.name == "firm_session" }) else { done(); return }
            var req = URLRequest(url: URL(string: "https://getstubbie.com/dashboard/alerts")!)
            req.setValue("firm_session=\(s.value)", forHTTPHeaderField: "Cookie")
            req.setValue("FirmApp/1.2", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { done() }
                guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = j["alerts"] as? [[String: Any]] else { return }
                let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
                let alt = ISO8601DateFormatter(); alt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let parse: (String) -> Date? = { iso.date(from: $0) ?? alt.date(from: $0) ?? Alerts.loose($0) }
                let last = UserDefaults.standard.double(forKey: self.seenKey)
                var newest = last
                let firstRun = last == 0
                for a in list.reversed() {
                    guard let at = a["at"] as? String, let d = parse(at) else { continue }
                    let t = d.timeIntervalSince1970
                    if t > last {
                        newest = max(newest, t)
                        if firstRun { continue }               // don't replay history on first launch
                        let n = UNMutableNotificationContent()
                        n.title = (a["title"] as? String) ?? "The Firm"
                        n.body = ((a["body"] as? String) ?? "").replacingOccurrences(of: "**", with: "")
                        n.sound = .default
                        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "firm-\(Int(t))", content: n, trigger: nil))
                    }
                }
                if newest > last { UserDefaults.standard.set(newest, forKey: self.seenKey) }
            }.resume()
        }
    }
    // "2026-09-10T20:24:15+0200" style, without the colon ISO8601DateFormatter wants
    static func loose(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f.date(from: s)
    }
    // banners even while the app is open
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([.banner, .sound]) }
}
