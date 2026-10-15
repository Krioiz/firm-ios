import ActivityKit
import Foundation

// Starts and feeds the basket's Live Activity. The server does the ticking while the app is closed:
// every activity's push token (and the phone's push-to-start token, so the server can start the
// next basket's activity by itself) goes to /book/live-activity. While the app is open, each live
// tick also updates the activity directly.
@MainActor enum BasketActivity {
    static var current: Activity<BasketAttributes>? { Activity<BasketAttributes>.activities.first }
    static var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Once, at launch: hand the push-to-start token to the server, and pick up activities already running.
    static func observe() {
        Task {
            for await data in Activity<BasketAttributes>.pushToStartTokenUpdates { register(data, kind: "start", id: nil) }
        }
        for a in Activity<BasketAttributes>.activities { watch(a) }
    }

    static func state(_ s: LiveSnap) -> (BasketAttributes, BasketAttributes.ContentState)? {
        guard let k = s.books?["kraken-1h"], let kr = k.net_kr, let bp = k.net_bp,
              let c = k.closes_at, let close = Tradster.date(c) else { return nil }
        let legs = (s.legs ?? []).filter { $0.book == "kraken-1h" && $0.bp != nil }.sorted { $0.bp! > $1.bp! }
        guard let b = legs.first, let w = legs.last else { return nil }
        return (BasketAttributes(book: "kraken-1h", title: "Momentum-kurven", closesAt: close.timeIntervalSince1970),
                .init(netKr: kr, netBp: bp, best: b.symbol ?? "", bestBp: b.bp ?? 0, worst: w.symbol ?? "", worstBp: w.bp ?? 0,
                      updated: Date().timeIntervalSince1970))
    }

    static func start(_ s: LiveSnap) {
        guard enabled, current == nil, let pair = state(s) else { return }
        let (attr, st) = pair
        do {
            let a = try Activity.request(attributes: attr,
                                         content: .init(state: st, staleDate: Date().addingTimeInterval(15 * 60)),
                                         pushType: .token)
            watch(a)
        } catch { NSLog("[activity] start failed: \(error.localizedDescription)") }
    }

    static func stop() {
        for a in Activity<BasketAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        register(nil, kind: "stop", id: nil)
    }

    /// From the app's own live ticks while it is open.
    static func update(_ s: LiveSnap) {
        guard let a = current, let pair = state(s) else { return }
        let (attr, st) = pair
        if attr.closesAt != a.attributes.closesAt {            // a new basket: this activity is over
            Task { await a.end(nil, dismissalPolicy: .immediate); start(s) }
            return
        }
        Task { await a.update(.init(state: st, staleDate: Date().addingTimeInterval(15 * 60))) }
    }

    private static func watch(_ a: Activity<BasketAttributes>) {
        Task { for await data in a.pushTokenUpdates { register(data, kind: "update", id: a.id) } }
    }

    private static func register(_ token: Data?, kind: String, id: String?) {
        var body: [String: Any] = ["kind": kind]
        if let token { body["token"] = token.map { String(format: "%02x", $0) }.joined() }
        if let id { body["activity_id"] = id }
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/live-activity")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r).resume()
    }
}
