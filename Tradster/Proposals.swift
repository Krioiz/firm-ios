import SwiftUI

// What Koda's lab found, at the top of "Bogen". A proposal is a rule that passed its one holdout test;
// "Start på papir" is Marco's tap and nobody else's -- the server only accepts it from his paired phone.

struct PropStat: Codable, Hashable, Sendable { let net_bp: Double?; let t: Double?; let n: Int? }
struct PropBook: Codable, Hashable, Sendable { let equity: Double?; let start: Double?; let net_bp: Double?; let n_trades: Int? }
struct Proposal: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String?; let summary: String?; let insample: PropStat?; let holdout: PropStat?
    let created_at: String?; let status: String?; let book: PropBook?
    var runnable: Bool? = nil   // only a Kraken rule can run as a paper book
}
struct ProposalFeed: Codable, Sendable {
    var items: [Proposal]
    enum CodingKeys: String, CodingKey { case items }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        items = ((try? c.decodeIfPresent([Lossy<Proposal>].self, forKey: .items)) ?? nil)?.compactMap(\.value) ?? []
    }
}
struct LabStatus: Codable, Sendable {
    let runs_today: Int?; let spend_today: Double?; let tested: Int?; let candidates: Int?; let passed: Int?
}

@MainActor final class ProposalModel: ObservableObject {
    static let shared = ProposalModel()
    @Published var items: [Proposal] = []
    @Published var lab: LabStatus? = nil
    @Published var busy: String? = nil
    @Published var error: String? = nil

    private func req(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/\(path)")!)
        r.httpMethod = method; r.timeoutInterval = 20; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    func load() async {
        async let p = try? URLSession.shared.data(for: req("proposals"))
        async let l = try? URLSession.shared.data(for: req("edgelab"))
        if let res = await p, (res.1 as? HTTPURLResponse)?.statusCode == 200, let f = await BookChatModel.decode(ProposalFeed.self, res.0) {
            withAnimation(.snappy) { items = f.items }
        }
        if let res = await l, (res.1 as? HTTPURLResponse)?.statusCode == 200, let s = await BookChatModel.decode(LabStatus.self, res.0) { lab = s }
    }
    func decide(_ id: String, _ decision: String) async {
        busy = id; error = nil; defer { busy = nil }
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        guard let res = try? await URLSession.shared.data(for: req("proposals/\(enc)/decision", "POST", ["decision": decision])),
              (res.1 as? HTTPURLResponse)?.statusCode == 200 else { error = "Kunne ikke gemme dit valg"; return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await load()
    }
}

private func bp(_ v: Double?) -> String {
    guard let v else { return "–" }
    return "\(v >= 0 ? "+" : "−")\(Int(abs(v).rounded())) bp"
}

/// The lab in one line, then each proposal.
struct LabSection: View {
    @ObservedObject var m = ProposalModel.shared
    @State private var confirm: Proposal? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let l = m.lab {
                HStack(spacing: 6) {
                    Image(systemName: "flask").font(.system(size: 12, weight: .semibold))
                    Text("Koda har testet \(l.tested ?? 0) idéer · \(l.passed ?? 0) bestået · \(l.runs_today ?? 0) kørsler i dag")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            ForEach(m.items.filter { $0.status != "afvist" }) { p in card(p) }
            if let e = m.error { Text(e).font(.system(size: 13)).foregroundStyle(Theme.down) }
        }
        .task { await m.load() }
        .confirmationDialog("Start på papir?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { p in
            Button("Start på papir (5.000 kr papir)") { Task { await m.decide(p.id, "approve") } }
            Button("Annuller", role: .cancel) {}
        } message: { p in
            Text("\(p.title ?? "Reglen") kører selv hver time på papir til Krakens priser. Ingen rigtige penge.")
        }
    }

    private func card(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(p.title ?? p.id).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                statusPill(p.status)
            }
            if let s = p.summary { Text(s).font(.system(size: 15)).foregroundStyle(Theme.text.opacity(0.92)).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                stat("Test (gammel data)", p.insample)
                stat("Låst data", p.holdout)
                if let b = p.book { stat("På papir", PropStat(net_bp: b.net_bp, t: nil, n: b.n_trades)) }
            }
            HStack(spacing: 10) {
                switch p.status {
                case "venter" where p.runnable == false:
                    Text("Målt på Binance: kan ikke køre på Kraken-papir.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Button { Haptic.tap(); Task { await m.decide(p.id, "reject") } } label: { pill("Afvis", "xmark", Theme.secondary) }.buttonStyle(.plain)
                case "venter":
                    Button { Haptic.tap(); confirm = p } label: { pill("Start på papir", "play.fill", Theme.up) }.buttonStyle(.plain)
                    Button { Haptic.tap(); Task { await m.decide(p.id, "reject") } } label: { pill("Afvis", "xmark", Theme.secondary) }.buttonStyle(.plain)
                case "godkendt", "kører":
                    Button { Haptic.tap(); Task { await m.decide(p.id, "stop") } } label: { pill("Stop", "stop.fill", Theme.down) }.buttonStyle(.plain)
                default: EmptyView()
                }
                if m.busy == p.id { ProgressView().tint(Theme.secondary) }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private func stat(_ label: String, _ s: PropStat?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(bp(s?.net_bp)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle((s?.net_bp ?? 0) >= 0 ? Theme.up : Theme.down)
            Text([s?.t.map { String(format: "t %.1f", $0).replacingOccurrences(of: ".", with: ",") }, s?.n.map { "\($0) handler" }].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Theme.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func statusPill(_ s: String?) -> some View {
        let (t, c): (String, Color) = switch s {
            case "kører", "godkendt": ("Kører på papir", Theme.up)
            case "stoppet": ("Stoppet", Theme.secondary)
            default: ("Venter på dig", Theme.accent)
        }
        return Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(c)
            .padding(.horizontal, 10).padding(.vertical, 4).background(c.opacity(0.15), in: Capsule())
    }
    private func pill(_ t: String, _ icon: String, _ c: Color) -> some View {
        Label(t, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(c)
            .padding(.horizontal, 16).padding(.vertical, 10).modifier(Glass(interactive: true))
    }
}
