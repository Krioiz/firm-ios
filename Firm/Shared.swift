import Foundation

/// What the app and the home-screen widget share. The widget cannot see the app's Keychain
/// or memory; this suite is the one place both can read.
enum AppGroup {
    static let id = "group.com.getstubbie.firm"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

struct WidgetAlert: Codable, Hashable {
    let at: String; let title: String; let body: String
}

struct WidgetSnapshot: Codable {
    var updatedAt: Date
    var alerts: [WidgetAlert]
    var lutherEquity: Double?
    var lutherPnlPct: Double?
    var shopViews: Int?
    var shopSold: Int?
    var inboxCount: Int?

    static let key = "widget.snapshot"
    static func load() -> WidgetSnapshot? {
        guard let d = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: WidgetSnapshot.key) }
    }
}

/// The device identity the app was approved with, mirrored so the widget can open its own
/// session. The group container is sandboxed to this app and its extension.
enum SharedDevice {
    static var id: String? { AppGroup.defaults.string(forKey: "device.id") }
    static var secret: String? { AppGroup.defaults.string(forKey: "device.secret") }
    static func set(id: String, secret: String) {
        AppGroup.defaults.set(id, forKey: "device.id"); AppGroup.defaults.set(secret, forKey: "device.secret")
    }
}
