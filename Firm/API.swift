import Foundation
import WidgetKit
import SwiftUI

// Everything the app shows, decoded from the dashboard's own JSON endpoints.
// Every field is optional: the server is the source of truth and may add or drop keys,
// and a missing key must never blank the screen.
struct Agent: Codable, Identifiable, Hashable {
    // `tasks` is an ARRAY of task objects on the server, not a count. Declaring it as a
    // number made the whole payload fail to decode and the team list came back empty.
    // Only the fields actually used are declared; anything else is ignored.
    let id: String; let name: String?; let role: String?; let state: String?
    let spend: Double?; let tasksDone: Int?
    var working: Bool { state == "active" || state == "working" }
    var display: String { (name ?? id).prefix(1).uppercased() + (name ?? id).dropFirst() }
    var tidyRole: String { (role ?? "").lowercased().prefix(1).uppercased() + (role ?? "").lowercased().dropFirst() }
}
/// Decodes an array element by element, dropping any that fail. One malformed record
/// should cost that record, never the whole screen.
struct Lenient<T: Codable>: Codable {
    let items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer(); var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(AnyCodable.self) }
        }
        items = out
    }
    func encode(to encoder: Encoder) throws { var c = encoder.unkeyedContainer(); try c.encode(contentsOf: items) }
}
struct AnyCodable: Codable {}
struct StatePayload: Codable { let agents: Lenient<Agent>? }

struct CurvePoint: Codable, Hashable { let at: String?; let equity: Double? }
struct Bet: Codable, Identifiable, Hashable {
    let id: Int; let question: String?; let outcome: String?; let shares: Double?
    let avg_price: Double?; let cost: Double?; let value_now: Double?; let unrealised: Double?
    let probability: Double?; let thesis: String?; let falsifier: String?; let end_date: String?
}
struct Settled: Codable, Identifiable, Hashable {
    let id: Int; let question: String?; let outcome: String?; let probability: Double?
    let result: String?; let pnl: Double?; let cost: Double?; let closed_at: String?
}
struct Luther: Codable {
    let starting: Double?; let cash: Double?; let equity: Double?; let total_pnl: Double?
    let total_pnl_pct: Double?; let wins: Int?; let losses: Int?; let open_count: Int?
    let brier: Double?; let resolved_count: Int?; let brier_ready: Bool?; let broke: Bool?
    let curve: [CurvePoint]?; let open: [Bet]?; let settled: [Settled]?
}
struct Totals: Codable { let views: Int?; let favourites: Int?; let sold: Int?; let revenue: Double? }
struct Listing: Codable, Identifiable, Hashable {
    var id: Int { listing_id ?? 0 }
    let listing_id: Int?; let title: String?; let views: Int?; let favourites: Int?
    let sold: Int?; let price: Double?; let state: String?; let verdict: String?; let what_to_fix: String?
}
struct Sales: Codable { let totals: Totals?; let listings: [Listing]? }
struct Idea: Codable, Identifiable, Hashable {
    var id: String { (title ?? "") + (status ?? "") }
    let title: String?; let status: String?; let price_usd: Double?; let buyer: String?
    let owner: String?; let proposed_by: String?; let thesis: String?; let first_task: String?; let chair_why: String?
}
struct Lab: Codable { let ideas: [Idea]?; let last_session: String?; let advancing: Int? }
struct Card: Codable, Identifiable, Hashable {
    var id: String { (title ?? "") + String(days_in_stage ?? 0) }
    let title: String?; let holder: String?; let days_in_stage: Int?; let stuck: Bool?; let verdict: String?; let preview: String?
}
struct Stage: Codable, Identifiable, Hashable { var id: String { key ?? label ?? "" }; let key: String?; let label: String?; let cards: [Card]? }
struct Pipeline: Codable { let products: Int?; let stages: [Stage]? }
struct Product: Codable, Identifiable, Hashable {
    var id: String { slug ?? "" }
    let kind: String?; let slug: String?; let title: String?; let subtitle: String?; let images: [String]?
    let listing_id: Int?; let price: Double?; let state: String?; let views: Int?; let favourites: Int?
    let verdict: String?; let etsy_title: String?; let pages: Int?; let pdf: String?
}
struct Products: Codable { let posters: [Product]?; let packs: [Product]? }
struct Alert: Codable, Identifiable, Hashable { var id: String { (at ?? "") + (title ?? "") }; let at: String?; let title: String?; let body: String? }
struct Alerts: Codable { let alerts: [Alert]? }
struct Limits: Codable, Equatable { let daily_total_spend_cap: Double?; let per_agent_daily_cap: Double?; let publish_daily_cap: Double? }
struct DeviceRow: Codable, Identifiable, Hashable { var id: String { name ?? "" }; let name: String?; let created: String?; let lastUsed: String? }
struct TimerRow: Codable, Identifiable, Hashable { var id: String { unit ?? "" }; let unit: String?; let next: String? }
struct Settings: Codable { let limits: Limits?; let devices: [DeviceRow]?; let timers: [TimerRow]? }
struct Bot: Codable, Identifiable, Hashable { var id: String { agent ?? "" }; let agent: String?; let bot: String?; let connected: Bool?; let running: Bool? }
struct Day: Codable, Hashable {
    let date: String?; let spend: Double?; let working: Int?; let agents: Int?
    let views: Int?; let favourites: Int?; let sold: Int?; let revenue: Double?; let live: Int?; let equity: Double?
}
struct History: Codable { let days: [Day]? }

@MainActor final class Store: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var luther: Luther? = nil
    @Published var sales: Sales? = nil
    @Published var lab: Lab? = nil
    @Published var pipeline: Pipeline? = nil
    @Published var products: Products? = nil
    @Published var alerts: [Alert] = []
    @Published var settings: Settings? = nil
    @Published var bots: [Bot] = []
    @Published var history: [Day] = []
    @Published var inboxCount = 0
    @Published var loaded = false
    @Published var lastError: String? = nil
    @Published var needsApproval = false
    @Published var pairingCode: String? = nil
    private var haveSession = false

    static let base = "https://getstubbie.com/dashboard"
    private func get<T: Decodable>(_ path: String, _ type: T.Type) async -> T? {
        var r = URLRequest(url: URL(string: Store.base + path)!)
        r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode == 401 { haveSession = false; return nil }
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { lastError = "HTTP \(h.statusCode) on \(path)"; return nil }
            return try JSONDecoder().decode(T.self, from: d)
        } catch { lastError = error.localizedDescription; return nil }
    }
    /// Make sure the device has a session before asking for anything.
    func ensureSession() async -> Bool {
        if haveSession { return true }
        if await DeviceAuth.session() { haveSession = true; needsApproval = false; return true }
        needsApproval = true
        if pairingCode == nil { pairingCode = await DeviceAuth.requestCode() }
        return false
    }
    func refresh() async {
        guard await ensureSession() else { return }
        async let s: StatePayload? = get("/state", StatePayload.self)
        async let l: Luther? = get("/luther", Luther.self)
        async let sa: Sales? = get("/sales", Sales.self)
        async let lb: Lab? = get("/lab", Lab.self)
        async let pp: Pipeline? = get("/pipeline", Pipeline.self)
        async let pr: Products? = get("/products", Products.self)
        async let al: Alerts? = get("/alerts", Alerts.self)
        async let st: Settings? = get("/settings", Settings.self)
        async let bo: [Bot]? = get("/bots", [Bot].self)
        async let hi: History? = get("/history", History.self)
        async let ib: InboxPayload? = get("/inbox", InboxPayload.self)
        if let v = await s?.agents { agents = v.items }
        luther = await l; sales = await sa; lab = await lb; pipeline = await pp; products = await pr
        if let v = await al?.alerts { alerts = v }
        settings = await st
        if let v = await bo { bots = v }
        if let v = await hi?.days { history = v }
        inboxCount = await ib?.count ?? 0
        loaded = true
        WidgetCenter.shared.reloadAllTimelines()     // the widget fetches for itself; just wake it
        if agents.isEmpty && lastError == nil { lastError = "The server returned no agents." }
    }
    func saveCap(_ key: String, _ value: Double) async -> String? {
        var r = URLRequest(url: URL(string: Store.base + "/settings")!); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [key: value])
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                return (j?["error"] as? String) ?? "HTTP \(h.statusCode)"
            }
            await refresh(); return nil
        } catch { return error.localizedDescription }
    }
    func sendTest() async { _ = try? await URLSession.shared.data(for: {
        var r = URLRequest(url: URL(string: Store.base + "/push/test")!); r.httpMethod = "POST"
        r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent"); return r }()) }
}

// formatting shared across the app
enum Fmt {
    /// A number with no trailing .00 — for limits and bounds, not money.
    static func plain(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
    static func money(_ v: Double?) -> String {
        let n = v ?? 0
        return (n < 0 ? "-$" : "$") + String(format: "%.2f", abs(n))
    }
    static func signed(_ v: Double?) -> String {
        let n = v ?? 0
        return (n < 0 ? "-$" : "+$") + String(format: "%.2f", abs(n))
    }
    // Building a DateFormatter is genuinely expensive, and these run once per visible row.
    // Made once, reused, and the results memoised — scrolling a long log was doing
    // thousands of allocations a second for text that never changes.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let dayOut: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()
    private static let whenOut: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
    private static let cache = NSCache<NSString, NSString>()

    private static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFractional.date(from: s) ?? ymd.date(from: String(s.prefix(10)))
    }
    private static func memo(_ key: String, _ make: () -> String) -> String {
        if let hit = cache.object(forKey: key as NSString) { return hit as String }
        let v = make()
        cache.setObject(v as NSString, forKey: key as NSString)
        return v
    }
    static func day(_ s: String?) -> String {
        guard let s else { return "" }
        return memo("d|" + s) { parse(s).map { dayOut.string(from: $0) } ?? s }
    }
    static func when(_ s: String?) -> String {
        guard let s else { return "" }
        return memo("w|" + s) { parse(s).map { whenOut.string(from: $0) } ?? String(s.prefix(16)) }
    }
}
extension Color {
    static func agentHue(_ id: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .red, .teal, .pink, .cyan, .yellow, .indigo, .brown, .mint]
        var h = 0; for c in id.unicodeScalars { h = (h &* 31 &+ Int(c.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }
}
