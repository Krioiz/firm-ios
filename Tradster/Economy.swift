import SwiftUI

// Kodaconomy: Marco's own spending, read-only from Lunar via Enable Banking. The server categorises
// locally (no transaction ever goes to a model), pushes a "smæk" when a category runs hot, and does
// the savings math in code. Here: the month at a glance, categories against normal, the savings
// slider, subscriptions, the latest purchases and the last slaps.

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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kodaconomy").font(.system(size: 34, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                    Text(m.e?.month?.label.map { "Dit forbrug i \($0)" } ?? "Dit forbrug, læst fra Lunar").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 58)
                consentBanner
                if let mo = m.e?.month { headline(mo) }
                if let w = m.e?.week, let s = w.spent, let a = w.avg_spent, a > 0 { weekLine(s, a) }
                if let a = m.e?.alerts, !a.isEmpty { slaps(a) }
                if let cats = m.e?.month?.by_category, !cats.isEmpty { categories(cats) }
                simulator
                if let subs = m.e?.subscriptions, !subs.isEmpty { subscriptions(subs) }
                if let r = m.e?.recent, !r.isEmpty { recent(r) }
                if m.loading && m.e == nil { ProgressView().tint(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
                Text("Kun læseadgang til din konto. Posteringer sendes aldrig til en AI; Koda ser kun totaler pr. kategori. 7 % om året er en antagelse, ikke et løfte.")
                    .font(.footnote).foregroundStyle(Theme.secondary.opacity(0.7)).padding(.vertical, 20)
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
                Text(st == "udloeber_snart" ? "Adgangen til Lunar udløber snart." : "Ingen adgang til Lunar lige nu.")
                    .font(.system(size: 14)).foregroundStyle(Theme.text)
                Spacer()
                Button("Forbind") { Haptic.tap(); Task { if let u = await m.relink() { openURL(u) } } }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func headline(_ mo: EcoMonth) -> some View {
        let spent = mo.spent ?? 0, avg = mo.avg_spent ?? 0
        let over = avg > 0 ? (spent / avg - 1) * 100 : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Brugt indtil nu").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text(kr(spent)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                .contentTransition(.numericText(value: spent))
            HStack(spacing: 8) {
                if let p = mo.projected { Text("På vej mod \(kr(p))").foregroundStyle(p > avg * 1.05 && avg > 0 ? Theme.down : Theme.secondary) }
                if avg > 0 { Text("· normalt \(kr(avg))").foregroundStyle(Theme.secondary) }
            }
            .font(.system(size: 14)).monospacedDigit()
            if avg > 0 && abs(over) >= 5 {
                Text(over > 0 ? "\(Int(over.rounded())) % over din normale måned" : "\(Int((-over).rounded())) % under din normale måned")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(over > 0 ? Theme.down : Theme.up)
            }
        }
    }

    private func weekLine(_ s: Double, _ a: Double) -> some View {
        let ratio = s / a
        return HStack {
            Text("Denne uge").foregroundStyle(Theme.secondary)
            Spacer()
            Text(kr(s)).foregroundStyle(Theme.text).monospacedDigit()
            Text(String(format: "%.1f× normalt", ratio).replacingOccurrences(of: ".", with: ",")).monospacedDigit()
                .foregroundStyle(ratio > 1.2 ? Theme.down : Theme.secondary)
        }
        .font(.system(size: 15))
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func slaps(_ a: [EcoAlert]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Smæk")
            ForEach(a.prefix(3), id: \.self) { x in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Theme.down).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(x.text ?? "").font(.system(size: 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        Text(Tradster.when(x.at)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(16).background(Theme.down.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func categories(_ cats: [EcoCat]) -> some View {
        let top = cats.map { $0.kr ?? 0 }.max() ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            label("Kategorier")
            ForEach(cats, id: \.self) { c in
                let v = c.kr ?? 0, pct = c.vs_avg_pct ?? 0
                HStack(spacing: 12) {
                    Image(systemName: c.icon ?? "circle").font(.system(size: 15)).foregroundStyle(Theme.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(c.cat ?? "").font(.system(size: 15)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(kr(v)).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.surface2)
                                Capsule().fill(pct > 20 ? Theme.down : Theme.accent.opacity(0.8)).frame(width: max(4, g.size.width * v / max(top, 1)))
                            }
                        }
                        .frame(height: 5)
                        if abs(pct) >= 10 {
                            Text(pct > 0 ? "+\(Int(pct.rounded())) % over normalt" : "\(Int(pct.rounded())) % under normalt")
                                .font(.system(size: 12)).foregroundStyle(pct > 0 ? Theme.down : Theme.up)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// "Hvis du sparer X": a slider, and what it becomes.
    private var simulator: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Hvis du sparer …")
            HStack(alignment: .firstTextBaseline) {
                Text("\(kr(saving)) om måneden").font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: saving))
                Spacer()
            }
            Slider(value: $saving, in: 100...10000, step: 100).tint(Theme.accent)
                .onChange(of: saving) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
            HStack(spacing: 8) {
                fvTile("1 år", fv(saving, years: 1))
                fvTile("5 år", fv(saving, years: 5))
                fvTile("10 år", fv(saving, years: 10))
            }
            if let ex = m.e?.savings_examples, !ex.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ex, id: \.self) { s in
                        Button { Haptic.tap(); withAnimation(.snappy) { saving = min(10000, max(100, ((s.monthly_kr ?? 0) / 100).rounded() * 100)) } } label: {
                            HStack {
                                Text("Halvér \(s.cat?.lowercased() ?? "")").foregroundStyle(Theme.text)
                                Spacer()
                                Text("\(kr(s.monthly_kr ?? 0))/md → \(kr(s.fv_10y ?? 0)) på 10 år").monospacedDigit().foregroundStyle(Theme.up)
                            }
                            .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    private func subscriptions(_ subs: [EcoSub]) -> some View {
        let total = subs.reduce(0) { $0 + (($1.every == "år" ? ($1.kr ?? 0) / 12 : ($1.kr ?? 0))) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack { label("Abonnementer"); Spacer(); Text("\(kr(total))/md").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.secondary) }
            ForEach(subs, id: \.self) { s in
                HStack {
                    Text(s.name ?? "").font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text("\(kr(s.kr ?? 0))/\(s.every == "år" ? "år" : "md")").font(.system(size: 15)).monospacedDigit().foregroundStyle(Theme.text)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func recent(_ r: [EcoTx]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Seneste")
            ForEach(Array(r.prefix(15).enumerated()), id: \.offset) { _, t in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name ?? "").font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                        Text([t.cat, Tradster.when(t.at)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(kr(t.kr ?? 0)).font(.system(size: 15)).monospacedDigit().foregroundStyle(Theme.text)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary).textCase(.uppercase).kerning(0.6)
    }
}
