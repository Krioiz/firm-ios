import SwiftUI
import Charts
import PhotosUI

// ---- Tradster: the book as a conversation --------------------------------------------
// One screen, always dark: a serif greeting on an empty screen, a composer card at the bottom.
// Ask what we bought, sold, hold or closed; the answer is text from the firm's own model
// ("Bogen") or from the agents invited into the room, with the coins as cards: logo, side,
// entry -> mark, basis points and the hourly price since entry. Conversations live on the
// server, so the history drawer on the left shows them on every phone. The plus sends a photo.
// A number on a card never comes from a model: the server picks cards from the facts.

struct BookPt: Codable, Hashable { let t: Double; let c: Double }
struct BookCard: Codable, Identifiable, Hashable {
    var id: String { "\(book ?? "")/\(symbol ?? "")/\(status ?? "")/\(opened_at ?? "")" }
    let symbol: String?; let name: String?; let logo: String?; let logo_fallback: String?
    let book: String?; let side: String?; let status: String?
    let entry: Double?; let mark: Double?; let exit: Double?; let bp: Int?; let stop: Double?; let dkk: Double?
    let opened_at: String?; let closes_at: String?; let closed_at: String?; let why: String?; let note: String?
    let today: Bool?; let series: [BookPt]?
}
struct BookToday: Codable { let at: String?; let headline: String?; let cards: [BookCard]? }
struct AgentRow: Codable, Identifiable, Hashable { let id: String; let name: String?; let role: String? }
struct AgentsPayload: Codable { let agents: [AgentRow]? }
struct ServerMsg: Codable, Identifiable, Hashable {
    var id: String { "\(at ?? "")/\(role ?? "")/\(from ?? "")/\((text ?? "").prefix(20))" }
    let role: String?; let text: String?; let at: String?; let from: String?; let agent: String?
    let cards: [BookCard]?; let image: String?
}
struct ConvRow: Codable, Identifiable, Hashable {
    let id: String; let title: String?; let created: String?; let updated: String?; let agents: [String]?; let count: Int?; let last: String?
}
struct ConvList: Codable { let conversations: [ConvRow]? }
struct ConvDoc: Codable { let id: String; let title: String?; let agents: [String]?; let messages: [ServerMsg]?; let pending: Bool? }
struct SendResult: Codable { let id: String?; let title: String?; let agents: [String]?; let replies: [ServerMsg]?; let error: String? }

@MainActor final class BookChatModel: ObservableObject {
    @Published var messages: [ServerMsg] = []
    @Published var conversationId: String? = nil
    @Published var conversations: [ConvRow] = []
    @Published var agents: [AgentRow] = []
    @Published var selected: Set<String> = []
    @Published var sending = false
    @Published var error: String? = nil
    @Published var today: BookToday? = nil

    static let suggestions = ["Hvad købte vi i dag?", "Hvordan står bogen lige nu?", "Hvad er lukket med gevinst?", "Hvad ligger der i noteringsbogen?", "Hvilket ben taber mest?"]

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 60) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/\(path)")!)
        r.httpMethod = method
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = timeout
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }
    private func fetch<T: Decodable>(_ path: String, _ type: T.Type) async -> T? {
        guard let (d, _) = try? await URLSession.shared.data(for: request(path)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func bootstrap() async {
        async let t: BookToday? = fetch("today", BookToday.self)
        async let a: AgentsPayload? = fetch("agents", AgentsPayload.self)
        async let c: ConvList? = fetch("conversations", ConvList.self)
        today = await t
        if let v = await a?.agents { agents = v }
        if let v = await c?.conversations { conversations = v }
    }
    func refreshList() async { if let v = await fetch("conversations", ConvList.self)?.conversations { conversations = v } }

    var openCards: [BookCard] { (today?.cards ?? []).filter { $0.status == "open" } }
    var roomLabel: String {
        if selected.isEmpty { return "Bogen" }
        let names = agents.filter { selected.contains($0.id) }.map { $0.name ?? $0.id }
        return names.count > 2 ? "\(names[0]), \(names[1]) +\(names.count - 2)" : names.joined(separator: ", ")
    }

    func open(_ id: String) async {
        guard let doc = await fetch("conversations/\(id)", ConvDoc.self) else { return }
        conversationId = doc.id
        messages = doc.messages ?? []
        selected = Set(doc.agents ?? [])
    }
    func newChat() { conversationId = nil; messages = []; selected = [] }
    func delete(_ id: String) async {
        _ = try? await URLSession.shared.data(for: request("conversations/\(id)", method: "DELETE"))
        if conversationId == id { newChat() }
        await refreshList()
    }

    func send(_ text: String, image: UIImage? = nil) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || image != nil, !sending else { return }
        sending = true
        var payload: [String: Any] = ["message": body, "agents": Array(selected)]
        var localImage: String? = nil
        if let image, let jpeg = image.tradsterJPEG() {
            payload["image"] = jpeg.base64EncodedString()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try? jpeg.write(to: tmp); localImage = tmp.absoluteString
        }
        messages.append(ServerMsg(role: "user", text: body, at: ISO8601DateFormatter().string(from: Date()), from: nil, agent: nil, cards: nil, image: localImage))
        do {
            let (d, resp) = try await URLSession.shared.data(for: request("conversations/\(conversationId ?? "new")/message", method: "POST", body: payload, timeout: 240))
            let p = try? JSONDecoder().decode(SendResult.self, from: d)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                error = p?.error ?? "HTTP \(h.statusCode)"
            } else if let p {
                if let id = p.id { conversationId = id }
                messages.append(contentsOf: p.replies ?? [])
                await refreshList()
            } else {
                error = "Intet svar"
            }
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}

// ---- the one screen ---------------------------------------------------------------------
struct BookChatView: View {
    @StateObject private var model = BookChatModel()
    @State private var draft = ""
    @State private var pick: PhotosPickerItem? = nil
    @State private var photo: UIImage? = nil
    @State private var showHistory = false
    @State private var showBook = false
    @StateObject private var dictation = Dictation()
    @State private var pressStart: Date? = nil
    @State private var holdSend = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if model.messages.isEmpty { emptyState } else { thread }
                composer
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.bootstrap() }
        .sheet(isPresented: $showHistory) { HistoryView(model: model) }
        .sheet(isPresented: $showBook) { BookSheet(model: model) }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
                pick = nil
            }
        }
        .onChange(of: dictation.text) { _, t in if dictation.listening { draft = t } }
        .alert("Mikrofon og tale", isPresented: $dictation.denied) {
            Button("OK", role: .cancel) {}
        } message: { Text("Giv Tradster adgang til mikrofon og talegenkendelse under Indstillinger → Tradster.") }
        .alert("Kunne ikke svare", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private func roundButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
        }
    }

    private var topBar: some View {
        HStack {
            roundButton("line.3.horizontal") { showHistory = true }
            Spacer()
            if !model.messages.isEmpty {
                Text(model.roomLabel).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            roundButton(model.messages.isEmpty ? "book.closed" : "square.and.pencil") {
                if model.messages.isEmpty { showBook = true } else { withAnimation { model.newChat() } }
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<10: return "Godmorgen, hvad vil du vide?"
        case 10..<18: return "Goddag, hvordan går det?"
        default: return "Godaften, hvordan går det?"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "asterisk").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.accent).padding(.bottom, 26)
            Text(greeting)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.text).multilineTextAlignment(.center).padding(.horizontal, 28)
            if let h = model.today?.headline {
                Text(h).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).padding(.top, 14).padding(.horizontal, 40)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.messages) { m in BookBubble(m: m) }
                    if model.sending {
                        HStack(spacing: 8) {
                            Image(systemName: "asterisk").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            TypingDots()
                            Text(model.selected.isEmpty ? "" : "\(model.roomLabel) tænker").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }.padding(.horizontal, 20).id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: model.sending) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onAppear { proxy.scrollTo("bottom") }
        }
    }

    private var canSend: Bool { (!draft.trimmingCharacters(in: .whitespaces).isEmpty || photo != nil) && !model.sending }

    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let photo {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo).resizable().scaledToFill().frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button { self.photo = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.bg)
                                .frame(width: 20, height: 20).background(Theme.text, in: Circle())
                        }.offset(x: 6, y: -6)
                    }.padding(.leading, 6).padding(.top, 4)
                }
                TextField("", text: $draft, prompt: Text(model.selected.isEmpty ? "Spørg bogen" : "Skriv til \(model.roomLabel)").foregroundStyle(Theme.secondary), axis: .vertical)
                    .lineLimit(1...6).focused($focused)
                    .font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.accent)
                    .padding(.horizontal, 8).padding(.top, 6)
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.text)
                            .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
                    }
                    Menu {
                        Section("I rummet") {
                            Button { model.selected = [] } label: {
                                Label("Bogen (firmaets model)", systemImage: model.selected.isEmpty ? "checkmark" : "")
                            }
                        }
                        Section("Agenter — vælg én eller flere") {
                            ForEach(model.agents) { a in
                                Button {
                                    if model.selected.contains(a.id) { model.selected.remove(a.id) } else { model.selected.insert(a.id) }
                                } label: {
                                    Label(a.name ?? a.id, systemImage: model.selected.contains(a.id) ? "checkmark" : "")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.selected.isEmpty ? "asterisk" : "person.2").font(.system(size: 12, weight: .semibold))
                            Text(model.roomLabel).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).frame(height: 38).background(Theme.surface2, in: Capsule())
                    }
                    Spacer()
                    micButton
                    Button {
                        let t = draft, p = photo; draft = ""; photo = nil
                        Task { await model.send(t, image: p) }
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canSend ? Theme.bg : Theme.secondary)
                            .frame(width: 38, height: 38)
                            .background(canSend ? Theme.text : Theme.surface2, in: Circle())
                    }
                    .disabled(!canSend)
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
        .background(Theme.bg)
    }
}

extension BookChatView {
    /// Hold to talk: press, speak, release and it sends. A short tap starts dictation into the
    /// field instead, so you can read it over; tap again to stop.
    var micButton: some View {
        ZStack {
            if dictation.listening { Waveform(level: dictation.level) } else {
                Image(systemName: "mic").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
            }
        }
        .frame(width: 38, height: 38)
        .background(dictation.listening ? Theme.accent : Theme.surface2, in: Circle())
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
            if pressing {
                pressStart = Date()
                if dictation.listening { return }          // a tap while dictating: handled on release
                holdSend = false
                focused = false
                Task { await dictation.start() }
            } else {
                let held = Date().timeIntervalSince(pressStart ?? Date()) >= 0.35
                pressStart = nil
                if held {
                    let t = dictation.stop(); draft = ""
                    if !t.isEmpty { let p = photo; photo = nil; Task { await model.send(t, image: p) } }
                } else if holdSend == false, dictation.listening, draft.isEmpty == false, Date().timeIntervalSince(dictation.startedAt) > 0.6 {
                    draft = dictation.stop()                 // second tap: stop, keep the text to edit
                } else {
                    holdSend = false                         // first tap: keep listening
                }
            }
        })
        .accessibilityLabel("Tal")
    }
}

struct Waveform: View {
    let level: CGFloat
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Theme.bg)
                    .frame(width: 3, height: 6 + 16 * max(0.15, min(1, level * (i == 1 || i == 2 ? 1.0 : 0.6))))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// ---- history drawer -----------------------------------------------------------------------
struct HistoryView: View {
    @ObservedObject var model: BookChatModel
    @Environment(\.dismiss) private var dismiss
    private var groups: [(String, [ConvRow])] {
        let cal = Calendar.current
        var today: [ConvRow] = [], week: [ConvRow] = [], older: [ConvRow] = []
        for c in model.conversations {
            let d = ISO8601DateFormatter.withFraction.date(from: c.updated ?? "") ?? ISO8601DateFormatter().date(from: c.updated ?? "") ?? .distantPast
            if cal.isDateInToday(d) { today.append(c) }
            else if d > Date().addingTimeInterval(-7 * 86400) { week.append(c) }
            else { older.append(c) }
        }
        return [("I dag", today), ("Sidste 7 dage", week), ("Ældre", older)].filter { !$0.1.isEmpty }
    }
    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.newChat(); dismiss()
                } label: {
                    Label("Ny samtale", systemImage: "square.and.pencil").foregroundStyle(Theme.text)
                }.listRowBackground(Theme.surface)
                ForEach(groups, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { c in
                            Button {
                                Task { await model.open(c.id); dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.title ?? "Samtale").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text((c.agents ?? []).isEmpty ? "Bogen" : (c.agents ?? []).map { id in model.agents.first { $0.id == id }?.name ?? id }.joined(separator: ", "))
                                        Text("·"); Text(Tradster.when(c.updated))
                                    }.font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                            .listRowBackground(c.id == model.conversationId ? Theme.surface2 : Theme.surface)
                            .swipeActions { Button(role: .destructive) { Task { await model.delete(c.id) } } label: { Label("Slet", systemImage: "trash") } }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Samtaler").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Luk") { dismiss() }.foregroundStyle(Theme.secondary) } }
            .overlay { if model.conversations.isEmpty { Text("Ingen samtaler endnu").foregroundStyle(Theme.secondary) } }
            .task { await model.refreshList() }
        }
        .preferredColorScheme(.dark)
    }
}

// ---- the book, right now: every open leg -------------------------------------------------
struct BookSheet: View {
    @ObservedObject var model: BookChatModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let h = model.today?.headline { Text(h).font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.bottom, 4) }
                    ForEach(model.openCards) { CoinCard(c: $0) }
                    if model.openCards.isEmpty { Text("Bogen er flad.").foregroundStyle(Theme.secondary) }
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Bogen lige nu").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Luk") { dismiss() }.foregroundStyle(Theme.secondary) } }
            .refreshable { await model.bootstrap() }
        }
        .preferredColorScheme(.dark)
    }
}

// ---- messages ---------------------------------------------------------------------------
struct BookBubble: View {
    let m: ServerMsg
    private var mine: Bool { m.role == "user" }
    private var imageURL: URL? {
        guard let s = m.image, !s.isEmpty else { return nil }
        return s.hasPrefix("/") ? URL(string: "https://getstubbie.com\(s)") : URL(string: s)
    }
    var body: some View {
        if mine {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if let u = imageURL {
                        AsyncImage(url: u) { p in
                            if case .success(let img) = p { img.resizable().scaledToFill() } else { Theme.surface2 }
                        }
                        .frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if let t = m.text, !t.isEmpty {
                        Text(t).font(.system(size: 16)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }.padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: m.agent == nil ? "asterisk" : "person.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        if let f = m.from, f != "Bogen" { Text(f).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary) }
                        Text(m.text ?? "").font(.system(size: 16.5)).foregroundStyle(Theme.text).lineSpacing(3).textSelection(.enabled)
                    }
                }
                if let cs = m.cards, !cs.isEmpty {
                    VStack(spacing: 8) { ForEach(cs) { CoinCard(c: $0) } }.padding(.leading, 22)
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

extension UIImage {
    /// At most 1280 px on the long side, JPEG: a photo of a chart, not a 12 MB original.
    func tradsterJPEG() -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > 1280 ? 1280 / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let r = UIGraphicsImageRenderer(size: target, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let img = r.image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return img.jpegData(compressionQuality: 0.8)
    }
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
