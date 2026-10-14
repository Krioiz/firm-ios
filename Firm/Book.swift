import SwiftUI
import Charts

// ---- the book as a conversation ------------------------------------------------------
// "Hvad koebte vi i dag?" Ask, and the answer comes back as text from the firm's own model
// plus the coins it talks about as cards: name, logo, side, entry -> mark, basis points and
// the hourly price since entry. The cards are built by plain code on the server from the
// paper books on disk (GET /dashboard/book/today); the text is the model's (POST .../chat).
// A number on a card never comes from the model.

struct BookRef: Hashable { let id = "book" }

struct BookPt: Codable, Hashable { let t: Double; let c: Double }
struct BookCard: Codable, Identifiable, Hashable {
    var id: String { "\(book ?? "")/\(symbol ?? "")/\(status ?? "")/\(opened_at ?? "")" }
    let symbol: String?; let name: String?; let logo: String?; let logo_fallback: String?
    let book: String?; let side: String?; let status: String?
    let entry: Double?; let mark: Double?; let exit: Double?; let bp: Int?; let stop: Double?; let dkk: Double?
    let opened_at: String?; let closes_at: String?; let closed_at: String?; let why: String?; let note: String?
    let today: Bool?; let series: [BookPt]?
}
struct BookFill: Codable, Hashable {
    let at: String?; let book: String?; let symbol: String?; let side: String?; let size: Double?; let price: Double?
}
struct BookToday: Codable {
    let at: String?; let headline: String?; let cards: [BookCard]?; let fills: [BookFill]?
}
struct BookReply: Codable {
    let role: String?; let text: String?; let at: String?; let cards: [BookCard]?; let model: String?; let cost: Double?; let error: String?
}
struct BookMsg: Identifiable, Hashable {
    let id = UUID(); let role: String; let text: String; let at: String; let cards: [BookCard]
}

@MainActor final class BookChatModel: ObservableObject {
    @Published var messages: [BookMsg] = []
    @Published var sending = false
    @Published var error: String? = nil
    @Published var today: BookToday? = nil

    static let suggestions = ["Hvad købte vi i dag?", "Hvordan står bogen lige nu?", "Hvad er lukket med gevinst?", "Hvad ligger der i noteringsbogen?"]

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Store.base)/book/\(path)")!)
        r.httpMethod = method
        r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 90
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// The opening message is not a model's: it is the headline and the open legs, from disk.
    func load() async {
        guard let (d, _) = try? await URLSession.shared.data(for: request("today")),
              let t = try? JSONDecoder().decode(BookToday.self, from: d) else { return }
        today = t
        if messages.isEmpty {
            let open = (t.cards ?? []).filter { $0.status == "open" }
            messages.append(BookMsg(role: "assistant", text: t.headline ?? "Bogen er tom.", at: t.at ?? "", cards: open))
        }
    }

    func send(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        let history = messages.suffix(12).map { ["role": $0.role, "text": $0.text] }
        messages.append(BookMsg(role: "user", text: body, at: ISO8601DateFormatter().string(from: Date()), cards: []))
        do {
            let (d, resp) = try await URLSession.shared.data(for: request("chat", method: "POST", body: ["message": body, "history": history]))
            let p = try? JSONDecoder().decode(BookReply.self, from: d)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                error = p?.error ?? "HTTP \(h.statusCode)"
            } else if let p, let t = p.text {
                messages.append(BookMsg(role: "assistant", text: t, at: p.at ?? "", cards: p.cards ?? []))
            } else {
                error = "Intet svar"
            }
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}

struct BookChatView: View {
    @StateObject private var model = BookChatModel()
    @State private var draft = ""
    @State private var atBottom = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.messages) { m in BookBubble(m: m) }
                        if model.sending {
                            HStack { TypingDots(); Spacer() }.padding(.horizontal, 16).id("typing")
                        }
                        if model.messages.count <= 1 && !model.sending {
                            suggestions
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.vertical, 12)
                }
                .followsBottom($atBottom)
                .onChange(of: model.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: model.sending) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bogen").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Bogen").font(.system(size: 16, weight: .semibold))
                    Text(model.sending ? "tænker…" : "papir · Kraken").font(.system(size: 11))
                        .foregroundStyle(model.sending ? Color.accentColor : .secondary)
                }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Kunne ikke svare", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BookChatModel.suggestions, id: \.self) { s in
                    Button { Task { await model.send(s) } } label: {
                        Text(s).font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Spørg bogen…", text: $draft, axis: .vertical)
                .lineLimit(1...5).focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let t = draft; draft = ""
                Task { await model.send(t) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.sending ? Color.secondary : Color.accentColor)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.sending)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

struct BookBubble: View {
    let m: BookMsg
    private var mine: Bool { m.role == "user" }
    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 48) } else { bookAvatar }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    Text(m.text).font(.system(size: 16)).textSelection(.enabled)
                        .foregroundStyle(mine ? .white : .primary)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(Fmt.when(m.at)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !mine { Spacer(minLength: 48) }
            }
            if !m.cards.isEmpty {
                VStack(spacing: 8) { ForEach(m.cards) { CoinCard(c: $0) } }.padding(.leading, 34)
            }
        }.padding(.horizontal, 12)
    }
    private var bookAvatar: some View {
        Image(systemName: "book.closed.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(Color.indigo, in: Circle())
    }
}

struct CoinLogo: View {
    let url: String?; let fallback: String?; var size: CGFloat = 36
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFit()
            case .failure:
                AsyncImage(url: URL(string: fallback ?? "")) { p2 in
                    if case .success(let img) = p2 { img.resizable().scaledToFit() } else { placeholder }
                }
            default: placeholder
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }
    private var placeholder: some View {
        Circle().fill(Color.secondary.opacity(0.2)).overlay(Image(systemName: "bitcoinsign").font(.system(size: size * 0.4)).foregroundStyle(.secondary))
    }
}

struct CoinCard: View {
    let c: BookCard
    private var isShort: Bool { c.side == "short" }
    private var tint: Color { (c.bp ?? 0) >= 0 ? .green : .red }
    private func px(_ v: Double) -> String {
        v >= 100 ? String(format: "%.2f", v) : v >= 1 ? String(format: "%.4f", v) : String(format: "%.6g", v)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CoinLogo(url: c.logo, fallback: c.logo_fallback)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name ?? c.symbol ?? "").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(c.symbol ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(isShort ? "SHORT" : "LONG").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((isShort ? Color.orange : Color.blue).opacity(0.15), in: Capsule())
                            .foregroundStyle(isShort ? Color.orange : Color.blue)
                        Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let bp = c.bp {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(bp >= 0 ? "+\(bp) bp" : "\(bp) bp").font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                        if let d = c.dkk { Text(String(format: "%+.0f kr", d)).font(.system(size: 11)).foregroundStyle(.secondary) }
                        else if let e = c.entry, let m = c.mark { Text("\(px(e)) → \(px(m))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                } else if c.status == "waiting" {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
            }
            if let s = c.series, s.count > 2, let e = c.entry {
                let lo = min(s.map(\.c).min() ?? e, e), hi = max(s.map(\.c).max() ?? e, e), pad = max((hi - lo) * 0.1, 1e-9)
                Chart {
                    ForEach(Array(s.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("t", Date(timeIntervalSince1970: p.t)), y: .value("kurs", p.c))
                            .foregroundStyle(tint).lineStyle(.init(lineWidth: 2, lineCap: .round))
                    }
                    RuleMark(y: .value("ind", e)).foregroundStyle(.secondary.opacity(0.6)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("ind \(px(e))").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if let o = c.opened_at, let d = ISO8601DateFormatter().date(from: o) ?? ISO8601DateFormatter.withFraction.date(from: o) {
                        RuleMark(x: .value("aabnet", d)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(.init(lineWidth: 1))
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).hour()).font(.system(size: 9)) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.secondary.opacity(0.15)); AxisValueLabel().font(.system(size: 9)) } }
                .frame(height: 90)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private var statusLine: String {
        switch c.status {
        case "closed": return "lukket \(c.why ?? "") · \(Fmt.when(c.closed_at))"
        case "waiting": return c.note ?? "venter"
        default:
            let book = c.book == "listing" ? "notering" : "kurv"
            return "\(book) · åbnet \(Fmt.when(c.opened_at)) · ud \(Fmt.when(c.closes_at))"
        }
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
