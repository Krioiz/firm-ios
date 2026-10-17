import SwiftUI

// Kodaconomy: Marco's own spending, read-only from Lunar via Enable Banking. The server categorises
// locally (no transaction ever goes to a model), pushes a "smæk" when a category runs hot, and does
// the savings math in code. The page is deliberately quiet (Marco, 17 Oct 2026: "alt for rodet, alt
// for meget tekst"): one number, one line under it, the top five categories as bars, and three
// folded rows (sparer, abonnementer, seneste) that open on tap. No percentages in prose, no cards
// inside cards.

struct EcoConsent: Codable, Sendable { let status: String?; let valid_until: String?; let relink_url: String? }
struct EcoCat: Codable, Hashable, Sendable { let cat: String?; let kr: Double?; let avg_kr: Double?; let vs_avg_pct: Double?; let icon: String? }
struct EcoMonth: Codable, Sendable { let label: String?; let spent: Double?; let income: Double?; let avg_spent: Double?; let projected: Double?; let by_category: [EcoCat]? }
struct EcoWeek: Codable, Sendable { let spent: Double?; let avg_spent: Double? }
struct EcoSub: Codable, Hashable, Sendable { let name: String?; let kr: Double?; let every: String?; let last: String? }
struct EcoTx: Codable, Hashable, Sendable { let at: String?; let name: String?; let kr: Double?; let cat: String? }
struct EcoAlert: Codable, Hashable, Sendable { let at: String?; let text: String? }
struct EcoSaving: Codable, Hashable, Sendable { let cat: String?; let monthly_kr: Double?; let fv_1y: Double?; let fv_5y: Double?; let fv_10y: Double? }
struct Economy: Codable, Sendable {
    let at: String?; let consent: EcoConsent?; let month: EcoMonth?; let week: EcoWeek?
    let subscriptions: [EcoSub]?; let recent: [EcoTx]?; let alerts: [EcoAlert]?; let savings_examples: [EcoSaving]?
}

@MainActor final class EconomyModel: ObservableObject {
    @Published var e: Economy? = Disk.load(Economy.self, "economy.json")
    @Published var loading = false
    private func req(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/\(path)")!)
        r.httpMethod = method; r.timeoutInterval = 25; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    func load() async {
        loading = e == nil; defer { loading = false }
        guard let res = try? await URLSession.shared.data(for: req("economy")), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let v = await BookChatModel.decode(Economy.self, res.0) else { return }
        withAnimation(.snappy) { e = v }
        Disk.save(v, "economy.json")
    }
    func relink() async -> URL? {
        guard let res = try? await URLSession.shared.data(for: req("economy/relink", "POST", [:])),
              let j = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any],
              let s = (j["url"] ?? j["relink_url"]) as? String else { return nil }
        return URL(string: s)
    }
}

/// Future value of saving `m` kr every month at 7 % a year — the same math the server uses.
private func fv(_ m: Double, years: Double, rate: Double = 0.07) -> Double {
    let r = pow(1 + rate, 1.0 / 12) - 1, n = years * 12
    return r == 0 ? m * n : m * (pow(1 + r, n) - 1) / r
}
private func kr(_ v: Double) -> String { "\(Tradster.kr(v)) kr" }

struct EconomyView: View {
    @StateObject private var m = EconomyModel()
    @Environment(\.openURL) private var openURL
    @State private var saving: Double = 1000
    @State private var allCats = false
    @State private var open: Set<String> = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Kodaconomy").font(.system(size: 34, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                    Spacer()
                    if let l = m.e?.month?.label { Text(l).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                }
                .padding(.top, 58)
                consentBanner
                if let mo = m.e?.month { headline(mo) }
                if let a = m.e?.alerts?.first, let t = a.text, !t.isEmpty { slap(t) }
                if let cats = m.e?.month?.by_category, !cats.isEmpty { categories(cats) }
                VStack(spacing: 0) {
                    fold("sparer", title: "Hvis du sparer", value: "\(kr(saving))/md → \(kr(fv(saving, years: 10))) på 10 år") { simulator }
                    if let subs = m.e?.subscriptions, !subs.isEmpty {
                        divider
                        fold("subs", title: "Abonnementer", value: "\(kr(subsMonthly(subs)))/md") { subscriptions(subs) }
                    }
                    if let r = m.e?.recent, !r.isEmpty {
                        divider
                        fold("recent", title: "Seneste", value: r.first.flatMap { $0.name } ?? "") { recent(r) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if m.loading && m.e == nil { ProgressView().tint(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
                Text("Kun læseadgang. Koda ser kun totaler pr. kategori.")
                    .font(.footnote).foregroundStyle(Theme.secondary.opacity(0.6)).padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
        }
        .background(Theme.bg)
        .refreshable { await m.load() }
        .task { await m.load() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var consentBanner: some View {
        let st = m.e?.consent?.status
        if st == "udloebet" || st == "mangler" || st == "udloeber_snart" {
            HStack(spacing: 10) {
                Image(systemName: "building.columns").foregroundStyle(Theme.accent)
                Text(st == "udloeber_snart" ? "Adgangen til Lunar udløber snart." : "Ingen adgang til Lunar.")
                    .font(.system(size: 14)).foregroundStyle(Theme.text)
                Spacer()
                Button("Forbind") { Haptic.tap(); Task { if let u = await m.relink() { openURL(u) } } }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// One number and one line. Red only when the month is heading more than 5 % over normal.
    private func headline(_ mo: EcoMonth) -> some View {
        let spent = mo.spent ?? 0, avg = mo.avg_spent ?? 0
        let hot = avg > 0 && (mo.projected ?? spent) > avg * 1.05
        return VStack(alignment: .leading, spacing: 6) {
            Text("Brugt denne måned").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(kr(spent)).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                .contentTransition(.numericText(value: spent))
            if let p = mo.projected, avg > 0 {
                Text("På vej mod \(kr(p)) · normalt \(kr(avg))").font(.system(size: 14)).monospacedDigit()
                    .foregroundStyle(hot ? Theme.down : Theme.secondary)
            }
            if let w = m.e?.week, let s = w.spent, let a = w.avg_spent, a > 0, s / a > 1.2 {
                Text("Denne uge \(kr(s)), normalt \(kr(a))").font(.system(size: 14)).monospacedDigit().foregroundStyle(Theme.down)
            }
        }
    }

    /// Only the latest slap, one line, no box.
    private func slap(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Theme.down).padding(.top, 3)
            Text(t).font(.system(size: 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Top five as bars. Red bar = more than 20 % over normal; the number says the rest.
    private func categories(_ cats: [EcoCat]) -> some View {
        let sorted = cats.sorted { ($0.kr ?? 0) > ($1.kr ?? 0) }
        let shown = allCats ? sorted : Array(sorted.prefix(5))
        let top = sorted.first?.kr ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(shown, id: \.self) { c in
                let v = c.kr ?? 0, pct = c.vs_avg_pct ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(c.cat ?? "").font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(kr(v)).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(pct > 20 ? Theme.down : Theme.text)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface2)
                            Capsule().fill(pct > 20 ? Theme.down : Theme.accent.opacity(0.75)).frame(width: max(4, g.size.width * v / max(top, 1)))
                        }
                    }
                    .frame(height: 4)
                }
            }
            if sorted.count > 5 {
                Button(allCats ? "Færre" : "Alle \(sorted.count)") { Haptic.tap(); withAnimation(.snappy) { allCats.toggle() } }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }
        }
    }

    /// A folded row: title left, one value right, chevron; the content opens under it on tap.
    private func fold<C: View>(_ key: String, title: String, value: String, @ViewBuilder _ content: () -> C) -> some View {
        let isOpen = open.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptic.tap()
                withAnimation(.snappy) { if isOpen { open.remove(key) } else { open.insert(key) } }
            } label: {
                HStack(spacing: 10) {
                    Text(title).font(.system(size: 15)).foregroundStyle(Theme.text)
                    Spacer()
                    if !isOpen {
                        Text(value).font(.system(size: 14)).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 15).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content().padding(.horizontal, 16).padding(.bottom, 16) }
        }
    }
    private var divider: some View { Rectangle().fill(Theme.surface2).frame(height: 1).padding(.horizontal, 16) }

    private var simulator: some View {
        VStack(alignment: .leading, spacing: 12) {
            Slider(value: $saving, in: 100...10000, step: 100).tint(Theme.accent)
                .onChange(of: saving) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
            HStack(spacing: 8) {
                fvTile("1 år", fv(saving, years: 1))
                fvTile("5 år", fv(saving, years: 5))
                fvTile("10 år", fv(saving, years: 10))
            }
            if let s = m.e?.savings_examples?.first, let c = s.cat, let mk = s.monthly_kr, mk > 0 {
                Button { Haptic.tap(); withAnimation(.snappy) { saving = min(10000, max(100, (mk / 100).rounded() * 100)) } } label: {
                    Text("Halvér \(c.lowercased()): \(kr(mk))/md").font(.system(size: 14)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Text("7 % om året er en antagelse.").font(.system(size: 12)).foregroundStyle(Theme.secondary.opacity(0.7))
        }
    }
    private func fvTile(_ l: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(kr(v)).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.up)
                .contentTransition(.numericText(value: v)).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Theme.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func subsMonthly(_ subs: [EcoSub]) -> Double { subs.reduce(0) { $0 + ($1.every == "år" ? ($1.kr ?? 0) / 12 : ($1.kr ?? 0)) } }
    private func subscriptions(_ subs: [EcoSub]) -> some View {
        VStack(spacing: 0) {
            ForEach(subs, id: \.self) { s in
                HStack {
                    Text(s.name ?? "").font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text("\(kr(s.kr ?? 0))/\(s.every == "år" ? "år" : "md")").font(.system(size: 15)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func recent(_ r: [EcoTx]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(r.prefix(10).enumerated()), id: \.offset) { _, t in
                HStack {
                    Text(t.name ?? "").font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(Tradster.when(t.at)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text(kr(t.kr ?? 0)).font(.system(size: 15)).monospacedDigit().foregroundStyle(Theme.text).frame(minWidth: 72, alignment: .trailing)
                }
                .padding(.vertical, 7)
            }
        }
    }
}
