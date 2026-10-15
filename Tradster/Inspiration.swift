import SwiftUI

// Inspiration: what is coming to market. A researcher on the server (scripts/inspiration.py, twice a
// day) reads the IPO calendars, new coins and new Kraken perps, and writes a few Danish lines on each.
// Information only: the page never says buy, and "Spørg Koda" hands the name to the chat.

struct InspoNumber: Codable, Hashable, Sendable { let label: String?; let value: String? }
struct InspoSource: Codable, Hashable, Sendable { let title: String?; let url: String? }
struct InspoItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let kind: String?; let name: String?; let ticker: String?; let venue: String?; let date: String?; let status: String?
    let logo: String?; let headline: String?; let why: String?; let risk: String?
    let numbers: [InspoNumber]?; let sources: [InspoSource]?; let score: Int?; let tradable_for_us: String?
}
struct InspoFeed: Codable, Sendable {
    var at: String?; var items: [InspoItem]
    enum CodingKeys: String, CodingKey { case at, items }
    /// One odd item must never cost the page.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(String.self, forKey: .at)) ?? nil
        items = ((try? c.decodeIfPresent([Lossy<InspoItem>].self, forKey: .items)) ?? nil)?.compactMap(\.value) ?? []
    }
}

@MainActor final class InspoModel: ObservableObject {
    @Published var items: [InspoItem] = []
    @Published var at: String? = nil
    @Published var loading = false
    init() {
        if let f = Disk.load(InspoFeed.self, "inspiration.json") { items = f.items; at = f.at }
    }
    func load() async {
        loading = items.isEmpty
        defer { loading = false }
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/inspiration")!)
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 20
        guard let res = try? await URLSession.shared.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let f = await BookChatModel.decode(InspoFeed.self, res.0) else { return }
        withAnimation(.snappy) { items = f.items; at = f.at }
        Disk.save(f, "inspiration.json")
    }
}

/// Liquid Glass where the phone has it (iOS 26), a material on iOS 18.
struct Glass: ViewModifier {
    var tint: Color? = nil
    var interactive = false
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .background((tint ?? .clear).opacity(0.25), in: Capsule())
        }
    }
}

struct InspirationView: View {
    @StateObject private var model = InspoModel()
    @State private var filter = "alle"
    @State private var open: String? = nil
    private let filters = [("alle", "Alle"), ("aktie", "Aktier"), ("crypto", "Crypto"), ("andet", "Andet")]

    private var shown: [InspoItem] { filter == "alle" ? model.items : model.items.filter { ($0.kind ?? "andet") == filter } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inspiration").font(.system(size: 34, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 58)   // under the top pill
                    WatchStrip()
                    chips
                    if model.loading { ForEach(0..<3, id: \.self) { _ in placeholder } }
                    else if shown.isEmpty {
                        Text(model.items.isEmpty ? "Researcheren har ikke skrevet noget endnu. Træk ned for at hente." : "Intet i denne kategori lige nu.")
                            .font(.system(size: 15)).foregroundStyle(Theme.secondary).padding(.top, 30)
                    }
                    ForEach(groups, id: \.0) { g in
                        Text(g.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .textCase(.uppercase).kerning(0.6).padding(.top, 10)
                        ForEach(g.1) { it in
                            InspoCard(it: it, open: open == it.id) {
                                Haptic.tap()
                                withAnimation(.snappy(duration: 0.3)) { open = open == it.id ? nil : it.id }
                            }
                        }
                    }
                    Text("Kun information. Ingen anbefaling om køb eller salg.")
                        .font(.footnote).foregroundStyle(Theme.secondary.opacity(0.7)).frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                .padding(.horizontal, 16)
            }
            .background(Theme.bg)
            .refreshable { async let a: Void = model.load(); async let b: Void = WatchModel.shared.load(); _ = await (a, b) }
            .task { async let a: Void = model.load(); async let b: Void = WatchModel.shared.load(); _ = await (a, b) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    /// Soonest first, in plain groups, so the page reads as a calendar.
    private var groups: [(String, [InspoItem])] {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        func days(_ it: InspoItem) -> Int? {
            guard let s = it.date, let d = Tradster.day(s) else { return nil }
            return cal.dateComponents([.day], from: today, to: d).day
        }
        var now: [InspoItem] = [], soon: [InspoItem] = [], done: [InspoItem] = [], talk: [InspoItem] = []
        for it in shown {
            if it.status == "rygte" { talk.append(it); continue }
            switch days(it) {
            case .some(let d) where d >= 0 && d <= 1: now.append(it)
            case .some(let d) where d > 1: soon.append(it)
            case .some: done.append(it)
            case .none: if it.status == "kommende" { soon.append(it) } else { done.append(it) }
            }
        }
        soon.sort { (days($0) ?? 999) < (days($1) ?? 999) }
        done.sort { (days($0) ?? -999) > (days($1) ?? -999) }
        return [("I dag og i morgen", now), ("Snart", soon), ("Allerede på markedet", done), ("Planer og rygter", talk)].filter { !$0.1.isEmpty }
    }

    private var subtitle: String {
        guard let a = model.at else { return "Børsnoteringer og nye coins, set af researcheren" }
        return "Opdateret \(Tradster.when(a)) · børsnoteringer og nye coins"
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.0) { f in
                    Button {
                        Haptic.tap(); withAnimation(.snappy) { filter = f.0 }
                    } label: {
                        Text(f.1).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(filter == f.0 ? Theme.bg : Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .modifier(Glass(tint: filter == f.0 ? Theme.text : nil, interactive: true))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface).frame(height: 132)
            .modifier(Shimmer())
    }
}

struct InspoCard: View {
    let it: InspoItem; let open: Bool; let toggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                CachedImage(url: it.logo, px: 132) {
                    RoundedRectangle(cornerRadius: 11).fill(Theme.surface2)
                        .overlay(Text(String((it.ticker ?? it.name ?? "?").prefix(2))).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary))
                }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.name ?? it.ticker ?? "").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text([kindLabel, it.venue].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                dateBadge
            }
            if let h = it.headline {
                Text(h).font(.system(size: 17)).foregroundStyle(Theme.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if open {
                if let w = it.why { section("Hvad er det?") { para(w) } }
                if let n = it.numbers, !n.isEmpty {
                    section("Tallene") {
                        VStack(spacing: 0) {
                            ForEach(Array(n.enumerated()), id: \.offset) { i, x in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(x.label ?? "").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                                    Spacer(minLength: 12)
                                    Text(x.value ?? "–").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                        .monospacedDigit().multilineTextAlignment(.trailing)
                                }
                                .padding(.vertical, 9)
                                if i < n.count - 1 { Divider().overlay(Theme.line) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(Theme.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                if let r = it.risk { section("Hvad kan gå galt?") { para(r) } }
                if let t = it.tradable_for_us { section("Kan vi handle den?") { para(t) } }
                if let src = it.sources, !src.isEmpty {
                    section("Kilder") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(src, id: \.self) { s in
                                if let u = s.url, let url = URL(string: u) {
                                    Link(destination: url) {
                                        Label(s.title ?? url.host() ?? u, systemImage: "arrow.up.right.square")
                                            .font(.system(size: 14)).foregroundStyle(Theme.accent).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                FollowStar(it: it)
                Button {
                    Haptic.tap()
                    let q = "Fortæl mig om \(it.name ?? it.ticker ?? "den") \(it.ticker.map { "(\($0))" } ?? ""): hvad er historien, og hvad skal man holde øje med?"
                    NotificationCenter.default.post(name: AskKoda.note, object: nil, userInfo: ["q": q])
                } label: {
                    Label("Spørg Koda", systemImage: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 10).modifier(Glass(interactive: true))
                }
                .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Læs mere"); Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: open ? .contain : .combine)
        .accessibilityHint(open ? "" : "Vis mere")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            c()
        }
    }
    private func para(_ t: String) -> some View {
        Text(t).font(.system(size: 16)).foregroundStyle(Theme.text.opacity(0.94)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
    }

    private var kindLabel: String? {
        switch it.kind { case "aktie": return "Aktie"; case "crypto": return "Crypto"; default: return nil }
    }
    private var dateBadge: some View {
        let (text, hot) = dateText
        return Text(text).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(hot ? Theme.bg : Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(hot ? Theme.accent : Theme.surface2, in: Capsule())
    }
    private var dateText: (String, Bool) {
        if it.status == "rygte" { return ("Rygte", false) }
        guard let s = it.date, let d = Tradster.day(s) else { return (it.status?.capitalized ?? "", false) }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: d).day ?? 0
        switch days {
        case 0: return ("I dag", true)
        case 1: return ("I morgen", true)
        case 2...30: return ("Om \(days) dage", days <= 7)
        case ..<0: return (days == -1 ? "I går" : "\(-days) dage siden", false)
        default:
            let f = DateFormatter(); f.locale = Locale(identifier: "da_DK"); f.dateFormat = "d. MMM"
            return (f.string(from: d), false)
        }
    }

}
