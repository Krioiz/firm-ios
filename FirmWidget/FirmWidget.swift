import WidgetKit
import SwiftUI

struct FirmEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
    let stale: Bool
}

/// Refreshes on its own every 30 minutes using the device identity the app mirrored into
/// the shared container — so the widget is current even when the app has not been opened.
struct FirmProvider: TimelineProvider {
    let base = "https://getstubbie.com/dashboard"

    func placeholder(in context: Context) -> FirmEntry {
        FirmEntry(date: .now, snap: WidgetSnapshot(updatedAt: .now,
            alerts: [WidgetAlert(at: "", title: "Luther WON — $29.24", body: "Fed +25bp in September")],
            lutherEquity: 1061.69, lutherPnlPct: 6.2, shopViews: 8, shopSold: 0, inboxCount: 2), stale: false)
    }
    func getSnapshot(in context: Context, completion: @escaping (FirmEntry) -> Void) {
        completion(FirmEntry(date: .now, snap: WidgetSnapshot.load(), stale: false))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FirmEntry>) -> Void) {
        Task {
            let fresh = await fetch()
            let snap = fresh ?? WidgetSnapshot.load()
            let stale = fresh == nil
            let entry = FirmEntry(date: .now, snap: snap, stale: stale)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }

    private func fetch() async -> WidgetSnapshot? {
        guard let id = SharedDevice.id, let secret = SharedDevice.secret else { return nil }
        // 1. open a session with the device identity (same handshake as the app)
        var sr = URLRequest(url: URL(string: "\(base)/auth/device/session")!)
        sr.httpMethod = "POST"; sr.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sr.setValue("FirmWidget/1", forHTTPHeaderField: "User-Agent")
        sr.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": id, "secret": secret])
        guard let (sd, sresp) = try? await URLSession.shared.data(for: sr),
              (sresp as? HTTPURLResponse)?.statusCode == 200,
              let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
              let tok = sj["token"] as? String else { return nil }
        func get(_ path: String) async -> [String: Any]? {
            var r = URLRequest(url: URL(string: base + path)!)
            r.setValue("firm_session=\(tok)", forHTTPHeaderField: "Cookie")
            r.setValue("FirmWidget/1", forHTTPHeaderField: "User-Agent")
            r.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        let alerts = await get("/alerts"); let luther = await get("/luther")
        let sales = await get("/sales"); let inbox = await get("/inbox")
        let rows = (alerts?["alerts"] as? [[String: Any]] ?? []).prefix(8).map {
            WidgetAlert(at: $0["at"] as? String ?? "", title: $0["title"] as? String ?? "", body: $0["body"] as? String ?? "")
        }
        let totals = sales?["totals"] as? [String: Any]
        var snap = WidgetSnapshot(updatedAt: .now, alerts: Array(rows),
                                  lutherEquity: luther?["equity"] as? Double,
                                  lutherPnlPct: luther?["total_pnl_pct"] as? Double,
                                  shopViews: totals?["views"] as? Int, shopSold: totals?["sold"] as? Int,
                                  inboxCount: inbox?["count"] as? Int)
        if rows.isEmpty, let old = WidgetSnapshot.load() { snap.alerts = old.alerts }
        snap.save()
        return snap
    }
}

// ---- views ---------------------------------------------------------------------------
struct FirmWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: FirmEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: lockScreen
            case .systemMedium: medium
            default: small
            }
        }
        .widgetURL(URL(string: "firm://today"))
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var alerts: [WidgetAlert] { entry.snap?.alerts ?? [] }
    private var todayCount: Int {
        let day = ISO8601DateFormatter().string(from: .now).prefix(10)
        return alerts.filter { $0.at.hasPrefix(day) }.count
    }
    private func when(_ s: String) -> String {
        // "2026-09-18T12:19:09Z" -> "12:19" local
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
        guard let d = iso.date(from: s) ?? iso2.date(from: s) else { return String(s.dropFirst(11).prefix(5)) }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                Text("The Firm").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if entry.stale { Image(systemName: "wifi.slash").font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
            if let a = alerts.first {
                Text(a.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                Text(a.body).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Text("\(when(a.at)) · \(todayCount) i dag").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Spacer(minLength: 0)
                Text("Ingen alarmer").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "bell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                    Text("Seneste").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if entry.stale { Image(systemName: "wifi.slash").font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
                if alerts.isEmpty {
                    Text("Ingen alarmer").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(alerts.prefix(3), id: \.self) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(when(a.at)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                        Text(a.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                stat("Luther", value: entry.snap?.lutherEquity.map { String(format: "$%.0f", $0) } ?? "—",
                     sub: entry.snap?.lutherPnlPct.map { String(format: "%+.1f%%", $0) } ?? "",
                     tint: (entry.snap?.lutherPnlPct ?? 0) >= 0 ? .green : .red)
                stat("Butik", value: "\(entry.snap?.shopSold ?? 0) solgt", sub: "\(entry.snap?.shopViews ?? 0) visninger", tint: .secondary)
                stat("Venter på dig", value: "\(entry.snap?.inboxCount ?? 0)", sub: "", tint: (entry.snap?.inboxCount ?? 0) > 0 ? .orange : .secondary)
            }
            .frame(width: 96, alignment: .leading)
        }
    }

    private func stat(_ label: String, value: String, sub: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(tint)
            if !sub.isEmpty { Text(sub).font(.system(size: 9)).foregroundStyle(.secondary) }
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let a = alerts.first {
                Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(a.body).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                Text("\(when(a.at)) · Luther \(entry.snap?.lutherEquity.map { String(format: "$%.0f", $0) } ?? "—")")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Text("The Firm").font(.system(size: 13, weight: .semibold))
                Text("Ingen alarmer").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

@main
struct FirmWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FirmAlerts", provider: FirmProvider()) { FirmWidgetView(entry: $0) }
            .configurationDisplayName("The Firm")
            .description("Seneste alarmer, Luther og butikken.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
