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
                    .padding(.top, 8)
                    chips
                    if model.loading { ForEach(0..<3, id: \.self) { _ in placeholder } }
                    else if shown.isEmpty {
                        Text(model.items.isEmpty ? "Researcheren har ikke skrevet noget endnu. Træk ned for at hente." : "Intet i denne kategori lige nu.")
                            .font(.system(size: 15)).foregroundStyle(Theme.secondary).padding(.top, 30)
                    }
                    ForEach(shown) { it in
                        InspoCard(it: it, open: open == it.id) {
                            Haptic.tap()
                            withAnimation(.snappy(duration: 0.3)) { open = open == it.id ? nil : it.id }
                        }
                    }
                    Text("Kun information. Ingen anbefaling om køb eller salg.")
                        .font(.footnote).foregroundStyle(Theme.secondary.opacity(0.7)).frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                .padding(.horizontal, 16)
            }
            .background(Theme.bg)
            .refreshable { await model.load() }
            .task { await model.load() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CachedImage(url: it.logo, px: 120) {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surface2)
                        .overlay(Text(String((it.ticker ?? it.name ?? "?").prefix(2))).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary))
                }
                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(it.name ?? it.ticker ?? "").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let t = it.ticker, t != it.name { Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary) }
                    }
                    Text([it.venue, kindLabel].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                dateBadge
            }
            if let h = it.headline { Text(h).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text) }
            if let s = it.score { scoreDots(s) }
            if open {
                if let w = it.why { Text(w).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.92)).fixedSize(horizontal: false, vertical: true) }
                if let n = it.numbers, !n.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(n, id: \.self) { x in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(x.label ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                                Text(x.value ?? "–").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                if let r = it.risk {
                    Label { Text(r) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                if let t = it.tradable_for_us {
                    Label { Text(t) } icon: { Image(systemName: "building.columns") }
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                if let src = it.sources, !src.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(src, id: \.self) { s in
                            if let u = s.url, let url = URL(string: u) {
                                Link(destination: url) {
                                    Label(s.title ?? url.host() ?? u, systemImage: "link").font(.system(size: 13)).foregroundStyle(Theme.accent).lineLimit(1)
                                }
                            }
                        }
                    }
                }
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
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: open ? .contain : .combine)
        .accessibilityHint(open ? "" : "Vis analysen")
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
    private func scoreDots(_ s: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in Circle().fill(i <= s ? Theme.accent : Theme.surface2).frame(width: 6, height: 6) }
            Text("interessant").font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.leading, 4)
        }
        .accessibilityElement().accessibilityLabel("Interessant \(s) af 5")
    }
}
