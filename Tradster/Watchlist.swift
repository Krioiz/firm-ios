import SwiftUI
import Charts

// The watchlist: names Marco follows, from Inspiration or by hand. The server (scripts/watchlist-watch.py,
// every 15 min) fetches prices, notices an IPO pricing, a first trading day, a big day move or real news,
// and pushes. Here: a strip at the top of Inspiration, a "Følg" button on every card, and a detail sheet.

struct WatchLast: Codable, Hashable, Sendable { let price: Double?; let currency: String?; let change_pct: Double?; let at: String? }
struct WatchEvent: Codable, Hashable, Sendable { let at: String?; let text: String? }
struct WatchItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String?; let ticker: String?; let kind: String?; let venue: String?; let logo: String?
    let added_at: String?; let source: String?; let date: String?
    let last: WatchLast?; let spark: [Double]?; let events: [WatchEvent]?
}
struct WatchFeed: Codable, Sendable {
    var at: String?; var items: [WatchItem]
    enum CodingKeys: String, CodingKey { case at, items }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil
        items = ((try? c.decodeIfPresent([Lossy<WatchItem>].self, forKey: .items)) ?? nil)?.compactMap(\.value) ?? []
    }
}

@MainActor final class WatchModel: ObservableObject {
    static let shared = WatchModel()
    @Published var items: [WatchItem] = []
    init() { if let f = Disk.load(WatchFeed.self, "watchlist.json") { items = f.items } }

    func follows(_ id: String) -> Bool { items.contains { $0.id == id } }

    private func req(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/\(path)")!)
        r.httpMethod = method; r.timeoutInterval = 20
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    func load() async {
        guard let res = try? await URLSession.shared.data(for: req("watchlist")), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let f = await BookChatModel.decode(WatchFeed.self, res.0) else { return }
        withAnimation(.snappy) { items = f.items }
        Disk.save(f, "watchlist.json")
    }
    func follow(_ it: InspoItem) async {
        var b: [String: Any] = ["id": it.id, "name": it.name ?? it.ticker ?? it.id, "source": "inspiration"]
        if let v = it.ticker { b["ticker"] = v }; if let v = it.kind { b["kind"] = v }; if let v = it.venue { b["venue"] = v }
        if let v = it.logo { b["logo"] = v }; if let v = it.date { b["date"] = v }
        _ = try? await URLSession.shared.data(for: req("watchlist", "POST", b))
        await load()
    }
    func unfollow(_ id: String) async {
        withAnimation(.snappy) { items.removeAll { $0.id == id } }
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        _ = try? await URLSession.shared.data(for: req("watchlist/\(enc)", "DELETE"))
        await load()
    }
}

private func changeText(_ p: Double) -> String {
    String(format: "%@%.1f", p >= 0 ? "+" : "−", abs(p)).replacingOccurrences(of: ".", with: ",") + " %"
}
private func priceText(_ l: WatchLast) -> String? {
    guard let p = l.price else { return nil }
    let f = NumberFormatter(); f.locale = Locale(identifier: "da_DK"); f.numberStyle = .decimal
    f.maximumFractionDigits = p < 1 ? 4 : 2; f.minimumFractionDigits = p < 1 ? 2 : 2
    return "\(f.string(from: NSNumber(value: p)) ?? "\(p)") \(l.currency ?? "")".trimmingCharacters(in: .whitespaces)
}

/// "Du følger": a row of small cards at the top of Inspiration.
struct WatchStrip: View {
    @ObservedObject var w = WatchModel.shared
    @State private var shown: WatchItem? = nil
    var body: some View {
        if !w.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Du følger").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .textCase(.uppercase).kerning(0.6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(w.items) { it in
                            Button { Haptic.tap(); shown = it } label: { chip(it) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .sheet(item: $shown) { WatchDetail(it: $0) }
        }
    }
    private func chip(_ it: WatchItem) -> some View {
        HStack(spacing: 10) {
            CachedImage(url: it.logo, px: 90) { Circle().fill(Theme.surface2) }
                .frame(width: 30, height: 30).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(it.ticker ?? it.name ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let p = it.last?.change_pct {
                    Text(changeText(p)).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(p >= 0 ? Theme.up : Theme.down)
                } else {
                    Text(it.date.flatMap { Tradster.day($0) }.map { "noteres \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? "venter")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(Theme.surface, in: Capsule())
    }
}

/// The "Følg" button on an Inspiration card.
struct FollowStar: View {
    let it: InspoItem
    @ObservedObject var w = WatchModel.shared
    var body: some View {
        let on = w.follows(it.id)
        Button {
            Haptic.tap()
            Task { if on { await w.unfollow(it.id) } else { await w.follow(it) } }
        } label: {
            Label(on ? "Følger" : "Følg", systemImage: on ? "star.fill" : "star")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Theme.accent : Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 10).modifier(Glass(interactive: true))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityHint(on ? "Stop med at følge" : "Få besked, når der sker noget")
    }
}

struct WatchDetail: View {
    let it: WatchItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        CachedImage(url: it.logo, px: 150) { Circle().fill(Theme.surface2) }
                            .frame(width: 48, height: 48).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.name ?? "").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                            Text([it.ticker, it.venue].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        }
                    }
                    if let l = it.last, let p = priceText(l) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(p).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                            if let c = l.change_pct { Text("\(changeText(c)) i dag").font(.system(size: 15, weight: .medium)).foregroundStyle(c >= 0 ? Theme.up : Theme.down) }
                        }
                    } else {
                        Text("Ikke på markedet endnu. Du får besked, når den bliver prissat, og på første handelsdag.")
                            .font(.system(size: 16)).foregroundStyle(Theme.secondary).lineSpacing(4)
                    }
                    if let s = it.spark, s.count > 2 {
                        let up = (s.last ?? 0) >= (s.first ?? 0)
                        Chart(Array(s.enumerated()), id: \.offset) { i, v in
                            LineMark(x: .value("t", i), y: .value("kurs", v)).interpolationMethod(.catmullRom)
                                .foregroundStyle(up ? Theme.up : Theme.down)
                            AreaMark(x: .value("t", i), yStart: .value("min", s.min() ?? 0), yEnd: .value("kurs", v))
                                .foregroundStyle(LinearGradient(colors: [(up ? Theme.up : Theme.down).opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: (s.min() ?? 0)...(s.max() ?? 1))
                        .frame(height: 120)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hvad er der sket").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                        if (it.events ?? []).isEmpty {
                            Text("Intet endnu. Researcheren kigger hvert kvarter.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                        }
                        ForEach(it.events ?? [], id: \.self) { e in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(.top, 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.text ?? "").font(.system(size: 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                                    Text(Tradster.when(e.at)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            Haptic.tap(); dismiss()
                            let q = "Hvordan går det med \(it.name ?? it.ticker ?? "den")\(it.ticker.map { " (\($0))" } ?? "")? Hvad er sket for nylig?"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: AskKoda.note, object: nil, userInfo: ["q": q]) }
                        } label: {
                            Label("Spørg Koda", systemImage: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 16).padding(.vertical, 10).modifier(Glass(interactive: true))
                        }.buttonStyle(.plain)
                        Button(role: .destructive) {
                            Haptic.tap(); Task { await WatchModel.shared.unfollow(it.id) }; dismiss()
                        } label: {
                            Label("Stop med at følge", systemImage: "star.slash").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.down)
                                .padding(.horizontal, 16).padding(.vertical, 10).modifier(Glass(interactive: true))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Luk") { dismiss() }.foregroundStyle(Theme.secondary) } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
