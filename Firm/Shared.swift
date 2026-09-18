import Foundation

struct WidgetAlert: Codable, Hashable { let at: String; let title: String; let body: String }

struct WidgetSnapshot: Codable {
    var updatedAt: Date
    var alerts: [WidgetAlert]
    var lutherEquity: Double?; var lutherPnlPct: Double?
    var shopViews: Int?; var shopSold: Int?; var inboxCount: Int?
    static let key = "widget.snapshot"
    static func load() -> WidgetSnapshot? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: WidgetSnapshot.key) } }
}
