import SwiftUI
import Charts

// ---- Tradster: the book as a conversation --------------------------------------------
// "Hvad koebte vi i dag?" Ask, and the answer comes back as text from the firm's own model
// plus the coins it talks about as cards: name, logo, side, entry -> mark, basis points and
// the hourly price since entry. The cards are built by plain code on the server from the
// paper books on disk (GET /dashboard/book/today); the text is the model's (POST .../chat).
// A number on a card never comes from the model.
//
// Look, by Marco's call (14 Oct 2026): like a chat app you would actually use -- one big
// serif question on an empty screen, a composer at the bottom, no tabs, always dark.

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

    static let suggestions = ["Hvad købte vi i dag?", "Hvordan står bogen lige nu?", "Hvad er lukket med gevinst?", "Hvad ligger der i noteringsbogen?", "Hvilket ben taber mest?"]

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/\(path)")!)
        r.httpMethod = method
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 90
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// The headline and the open legs, from disk, so the empty screen already knows the book.
    func load() async {
        guard let (d, _) = try? await URLSession.shared.data(for: request("today")),
              let t = try? JSONDecoder().decode(BookToday.self, from: d) else { return }
        today = t
    }

    var openCards: [BookCard] { (today?.cards ?? []).filter { $0.status == "open" } }

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

    func clear() { messages = [] }
}

// ---- the one screen ---------------------------------------------------------------------
struct BookChatView: View {
    @StateObject private var model = BookChatModel()
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if model.messages.isEmpty {
                    emptyState
                } else {
                    thread
                }
                composer
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .alert("Kunne ikke svare", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private var topBar: some View {
        HStack {
            Text("Tradster").font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Theme.text)
            Spacer()
            if !model.messages.isEmpty {
                Button { withAnimation { model.clear() } } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    /// The question, alone on the screen, until he asks one.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 70)
                Image(systemName: "asterisk").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent).padding(.bottom, 22)
                Text("Hvad vil du vide\nom bogen?")
                    .font(.system(size: 36, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.text).multilineTextAlignment(.center).lineSpacing(2)
                if let h = model.today?.headline {
                    Text(h).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center).padding(.top, 16).padding(.horizontal, 36)
                }
                VStack(spacing: 8) {
                    ForEach(BookChatModel.suggestions.prefix(3), id: \.self) { s in
                        Button { Task { await model.send(s) } } label: {
                            HStack {
                                Text(s).font(.system(size: 15)).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 40)
                if !model.openCards.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(model.openCards.prefix(6)) { c in
                            CoinLogo(url: c.logo, fallback: c.logo_fallback, size: 26)
                                .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                        }
                        Text("\(model.openCards.count) ben åbne").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.leading, 16)
                    }
                    .padding(.top, 28)
                }
                Spacer(minLength: 40)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.messages) { m in BookBubble(m: m) }
                    if model.sending {
                        HStack(spacing: 8) { Image(systemName: "asterisk").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent); TypingDots() }
                            .padding(.horizontal, 20).id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: model.sending) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !model.sending }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    ForEach(BookChatModel.suggestions, id: \.self) { s in
                        Button(s) { Task { await model.send(s) } }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34).background(Theme.surface2, in: Circle())
                }
                TextField("", text: $draft, prompt: Text("Spørg bogen").foregroundStyle(Theme.secondary), axis: .vertical)
                    .lineLimit(1...6).focused($focused)
                    .font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.accent)
                    .padding(.vertical, 7)
                Button {
                    let t = draft; draft = ""
                    Task { await model.send(t) }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSend ? Theme.bg : Theme.secondary)
                        .frame(width: 34, height: 34)
                        .background(canSend ? Theme.accent : Theme.surface2, in: Circle())
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
            Text("Papir på Kraken · ingen rigtige penge").font(.system(size: 11)).foregroundStyle(Theme.secondary.opacity(0.7)).padding(.bottom, 4)
        }
        .background(Theme.bg)
    }
}

// ---- messages ---------------------------------------------------------------------------
struct BookBubble: View {
    let m: BookMsg
    private var mine: Bool { m.role == "user" }
    var body: some View {
        if mine {
            HStack {
                Spacer(minLength: 60)
                Text(m.text).font(.system(size: 16)).foregroundStyle(Theme.text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }.padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "asterisk").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).padding(.top, 5)
                    Text(m.text).font(.system(size: 16.5)).foregroundStyle(Theme.text).lineSpacing(3).textSelection(.enabled)
                }
                if !m.cards.isEmpty {
                    VStack(spacing: 8) { ForEach(m.cards) { CoinCard(c: $0) } }.padding(.leading, 22)
                }
            }.padding(.horizontal, 20)
        }
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
        Circle().fill(Theme.surface2).overlay(Image(systemName: "bitcoinsign").font(.system(size: size * 0.4)).foregroundStyle(Theme.secondary))
    }
}

struct CoinCard: View {
    let c: BookCard
    private var isShort: Bool { c.side == "short" }
    private var tint: Color { (c.bp ?? 0) >= 0 ? Theme.up : Theme.down }
    private func px(_ v: Double) -> String {
        v >= 100 ? String(format: "%.2f", v) : v >= 1 ? String(format: "%.4f", v) : String(format: "%.6g", v)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CoinLogo(url: c.logo, fallback: c.logo_fallback)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name ?? c.symbol ?? "").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(c.symbol ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(isShort ? "SHORT" : "LONG").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((isShort ? Theme.down : Theme.up).opacity(0.18), in: Capsule())
                            .foregroundStyle(isShort ? Theme.down : Theme.up)
                        Text(statusLine).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let bp = c.bp {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(bp >= 0 ? "+\(bp) bp" : "\(bp) bp").font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                        if let d = c.dkk { Text(String(format: "%+.0f kr", d)).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                        else if let e = c.entry, let m = c.mark { Text("\(px(e)) → \(px(m))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary) }
                    }
                } else if c.status == "waiting" {
                    Image(systemName: "clock").foregroundStyle(Theme.secondary)
                }
            }
            if let s = c.series, s.count > 2, let e = c.entry {
                let lo = min(s.map(\.c).min() ?? e, e), hi = max(s.map(\.c).max() ?? e, e), pad = max((hi - lo) * 0.1, 1e-9)
                Chart {
                    ForEach(Array(s.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("t", Date(timeIntervalSince1970: p.t)), yStart: .value("lo", lo - pad), yEnd: .value("kurs", p.c))
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", Date(timeIntervalSince1970: p.t)), y: .value("kurs", p.c))
                            .foregroundStyle(tint).lineStyle(.init(lineWidth: 2, lineCap: .round))
                    }
                    RuleMark(y: .value("ind", e)).foregroundStyle(Theme.secondary.opacity(0.6)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("ind \(px(e))").font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                    if let o = c.opened_at, let d = ISO8601DateFormatter().date(from: o) ?? ISO8601DateFormatter.withFraction.date(from: o) {
                        RuleMark(x: .value("aabnet", d)).foregroundStyle(Theme.secondary.opacity(0.35)).lineStyle(.init(lineWidth: 1))
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).hour()).font(.system(size: 9)).foregroundStyle(Theme.secondary) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().font(.system(size: 9)).foregroundStyle(Theme.secondary) } }
                .frame(height: 96)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
    private var statusLine: String {
        switch c.status {
        case "closed": return "lukket \(c.why ?? "") · \(Tradster.when(c.closed_at))"
        case "waiting": return c.note ?? "venter"
        default:
            let book = c.book == "listing" ? "notering" : "kurv"
            return "\(book) · åbnet \(Tradster.when(c.opened_at)) · ud \(Tradster.when(c.closes_at))"
        }
    }
}

// ---- theme: always dark, warm, one accent ---------------------------------------------
enum Theme {
    static let bg = Color(red: 0.078, green: 0.074, blue: 0.070)        // #141312
    static let surface = Color(red: 0.125, green: 0.118, blue: 0.110)   // #201e1c
    static let surface2 = Color(red: 0.180, green: 0.170, blue: 0.160)  // #2e2b29
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.925, green: 0.910, blue: 0.885)      // #ece8e2
    static let secondary = Color(red: 0.600, green: 0.580, blue: 0.550) // #99948c
    static let accent = Color(red: 0.851, green: 0.502, blue: 0.369)    // #d9805e
    static let up = Color(red: 0.498, green: 0.820, blue: 0.627)        // #7fd1a0
    static let down = Color(red: 0.941, green: 0.478, blue: 0.431)      // #f07a6e
}

// ---- what this app needs from the rest of the firm, kept local so it builds alone -------
enum Tradster {
    static let base = "https://getstubbie.com/dashboard"
    static func when(_ s: String?) -> String {
        guard let s, let d = ISO8601DateFormatter().date(from: s) ?? ISO8601DateFormatter.withFraction.date(from: s) else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "da_DK")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d. MMM HH:mm"
        return f.string(from: d)
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

struct TypingDots: View {
    var scale: CGFloat = 1
    @State private var on = false
    var body: some View {
        HStack(spacing: 4 * scale) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.secondary).frame(width: 6 * scale, height: 6 * scale)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
    }
}
