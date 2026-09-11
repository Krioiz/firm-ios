import SwiftUI
import Charts

// ---- what the server sends ------------------------------------------------------------
struct ElliotTotals: Codable, Equatable {
    let value_dkk: Double?; let cost_dkk: Double?; let cash_dkk: Double?
    let total_dkk: Double?; let unrealised_dkk: Double?; let unrealised_pct: Double?
}
struct Freshness: Codable, Equatable {
    let portfolio_hours: Double?; let any_stale: Bool?; let stale_lines: [String]?
    let kronos_hours: Double?; let kronos_stale: Bool?
}
struct Position: Codable, Identifiable, Equatable {
    var id: String { (symbol ?? "") + "|" + (account ?? "") }
    let symbol: String?; let name: String?; let account: String?
    let quantity: Double?; let currency: String?; let price: Double?
    let day_change_pct: Double?; let change_pct_20d: Double?
    let value_dkk: Double?; let cost_dkk: Double?
    let unrealised_dkk: Double?; let unrealised_pct: Double?
    let weight_pct: Double?; let stale: Bool?; let as_of: String?
}
struct Call: Codable, Identifiable, Equatable {
    var id: String { (symbol ?? "") + (recorded_at ?? "") }
    let symbol: String?; let rating: String?; let action: String?
    let price_at_call: Double?; let currency: String?
    let recorded_at: String?; let thesis: String?
}
struct Announcement: Codable, Identifiable, Equatable {
    var id: String { (company ?? "") + (released ?? "") }
    let company: String?; let symbols: [String]?; let category: String?
    let headline: String?; let released: String?; let url: String?
}
struct Forecast: Codable, Identifiable, Equatable {
    var id: String { symbol ?? "" }
    let symbol: String?; let last_close: Double?; let median: Double?
    let median_return_pct: Double?; let p10: Double?; let p90: Double?
    let target_date: String?; let held: Bool?
}
struct KronosBlock: Codable, Equatable {
    let model: String?; let horizon_days: Int?; let generated_at: String?
    let trust: String?; let forecasts: [Forecast]?
}
struct ElliotPayload: Codable, Equatable {
    let generated_at: String?; let advisory: Bool?; let disclaimer: String?
    let totals: ElliotTotals?; let freshness: Freshness?
    let positions: [Position]?; let calls: [Call]?
    let announcements: [Announcement]?; let kronos: KronosBlock?
}

@MainActor final class ElliotModel: ObservableObject {
    @Published var data: ElliotPayload? = nil
    @Published var loaded = false
    func load() async {
        var r = URLRequest(url: URL(string: "\(Store.base)/elliot")!)
        r.setValue("FirmApp/6.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        defer { loaded = true }
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(ElliotPayload.self, from: d) else { return }
        if p != data { data = p }
    }
}

// ---- kroner, not dollars ---------------------------------------------------------------
enum DKK {
    static func money(_ v: Double?) -> String {
        guard let v else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.maximumFractionDigits = 0; f.groupingSeparator = "."
        return (f.string(from: NSNumber(value: v)) ?? "\(Int(v))") + " kr"
    }
    static func signed(_ v: Double?) -> String {
        guard let v else { return "—" }
        return (v >= 0 ? "+" : "") + money(v)
    }
    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.1f%%", v)
    }
    static func tint(_ v: Double?) -> Color {
        guard let v, v != 0 else { return .secondary }
        return v > 0 ? .green : .red
    }
}

struct ElliotView: View {
    @StateObject private var model = ElliotModel()

    var body: some View {
        List {
            if let d = model.data {
                headline(d)
                staleness(d)
                holdings(d)
                if let k = d.kronos, !(k.forecasts ?? []).isEmpty { kronos(k) }
                if !(d.calls ?? []).isEmpty { calls(d) }
                if !(d.announcements ?? []).isEmpty { news(d) }
                Section {
                    Text(d.disclaimer ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.data == nil && model.loaded {
                ContentUnavailableView("Nothing to show", systemImage: "chart.pie",
                    description: Text("Elliot has not written a portfolio yet."))
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    // The number Marco actually wants: what it is worth, and what it has cost him.
    @ViewBuilder private func headline(_ d: ElliotPayload) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your money, at Nordnet").font(.caption).foregroundStyle(.secondary)
                Text(DKK.money(d.totals?.total_dkk))
                    .font(.system(size: 38, weight: .bold)).monospacedDigit()
                HStack(spacing: 6) {
                    Image(systemName: (d.totals?.unrealised_dkk ?? 0) >= 0
                          ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                    Text(DKK.signed(d.totals?.unrealised_dkk)).monospacedDigit()
                    Text("(\(DKK.pct(d.totals?.unrealised_pct)))").monospacedDigit()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DKK.tint(d.totals?.unrealised_dkk))
                HStack(spacing: 14) {
                    Label(DKK.money(d.totals?.cash_dkk), systemImage: "banknote")
                    Label("\((d.positions ?? []).count) holdings", systemImage: "square.stack.3d.up")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }.padding(.vertical, 4)
        }
    }

    /// Advice built on stale prices is worse than no advice, so say so before anything else.
    @ViewBuilder private func staleness(_ d: ElliotPayload) -> some View {
        if let f = d.freshness {
            if f.any_stale == true || (f.kronos_stale == true) {
                Section {
                    if f.any_stale == true {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Some prices are old").font(.system(size: 14, weight: .semibold))
                                Text((f.stale_lines ?? []).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                    if f.kronos_stale == true, let h = f.kronos_hours {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Kronos has stopped forecasting")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Last run \(Int(h)) hours ago.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "wifi.slash").foregroundStyle(.orange) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func holdings(_ d: ElliotPayload) -> some View {
        Section("Holdings") {
            ForEach(d.positions ?? []) { p in PositionRow(p: p) }
        }
    }

    @ViewBuilder private func kronos(_ k: KronosBlock) -> some View {
        Section {
            ForEach(k.forecasts ?? []) { f in ForecastRow(f: f) }
        } header: {
            Text("Kronos — \(k.horizon_days ?? 5) days ahead")
        } footer: {
            Text(k.trust ?? "A forecast, not a promise. Forward-tested only.")
        }
    }

    @ViewBuilder private func calls(_ d: ElliotPayload) -> some View {
        Section("What Elliot has said") {
            ForEach(d.calls ?? []) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.symbol ?? "").font(.system(size: 15, weight: .semibold))
                        Text(c.rating ?? "").font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(ratingTint(c.rating).opacity(0.16), in: Capsule())
                            .foregroundStyle(ratingTint(c.rating))
                        Spacer()
                        Text(Fmt.when(c.recorded_at)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let t = c.thesis, !t.isEmpty {
                        Text(t).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private func news(_ d: ElliotPayload) -> some View {
        Section("Announcements on what you own") {
            ForEach(d.announcements ?? []) { a in
                if let u = a.url, let url = URL(string: u) {
                    Link(destination: url) { AnnouncementRow(a: a) }
                } else {
                    AnnouncementRow(a: a)
                }
            }
        }
    }

    private func ratingTint(_ r: String?) -> Color {
        switch (r ?? "").uppercased() {
        case "BUY", "ADD": return .green
        case "SELL", "TRIM": return .red
        default: return .secondary
        }
    }
}

private struct PositionRow: View {
    let p: Position
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.symbol ?? "").font(.system(size: 15, weight: .semibold))
                if p.stale == true {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                Spacer()
                Text(DKK.money(p.value_dkk)).font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            Text(p.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 10) {
                Text(DKK.signed(p.unrealised_dkk)).monospacedDigit()
                    .foregroundStyle(DKK.tint(p.unrealised_dkk))
                Text(DKK.pct(p.unrealised_pct)).monospacedDigit()
                    .foregroundStyle(DKK.tint(p.unrealised_pct))
                Spacer()
                Text("today \(DKK.pct(p.day_change_pct))").monospacedDigit()
                    .foregroundStyle(DKK.tint(p.day_change_pct))
            }.font(.system(size: 12, weight: .medium))
            // how much of the whole pot this one line is
            if let w = p.weight_pct {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(3, g.size.width * CGFloat(min(w, 100)) / 100))
                    }
                }.frame(height: 4)
            }
        }.padding(.vertical, 3)
    }
}

private struct ForecastRow: View {
    let f: Forecast
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(f.symbol ?? "").font(.system(size: 14, weight: .semibold))
                    if f.held == true {
                        Text("held").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("now \(fmt(f.last_close)) → \(fmt(f.median))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(DKK.pct(f.median_return_pct))
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DKK.tint(f.median_return_pct))
                Text("\(fmt(f.p10))–\(fmt(f.p90))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }.padding(.vertical, 2)
    }
    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: v >= 100 ? "%.0f" : "%.2f", v)
    }
}

private struct AnnouncementRow: View {
    let a: Announcement
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(a.company ?? "").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(String((a.released ?? "").prefix(10)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(a.headline ?? "").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            Text(a.category ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(.vertical, 2)
    }
}
