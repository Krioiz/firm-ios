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
    let kind: String?; let last: Double?; let change_pct: Double?; let prev_close: Double?; let currency: String?; let day_start: Double?; let status_text: String?
    var isMarket: Bool { kind == "market" }
}
struct BookToday: Codable { let at: String?; let headline: String?; let cards: [BookCard]? }
struct AgentRow: Codable, Identifiable, Hashable { let id: String; let name: String?; let role: String? }
struct AgentsPayload: Codable { let agents: [AgentRow]? }
struct ServerMsg: Codable, Identifiable, Hashable {
    var id: String { "\(at ?? "")/\(role ?? "")/\(from ?? "")/\((text ?? "").prefix(20))" }
    let role: String?; let text: String?; let at: String?; let from: String?; let agent: String?
    let cards: [BookCard]?; let image: String?
    var sources: [SourceRow]? = nil
}
struct SourceRow: Codable, Hashable { let kind: String?; let name: String?; let symbol: String?; let logo: String?; var url: String? = nil }
struct StreamEvent: Codable { let type: String; let id: String?; let title: String?; let text: String?; let source: SourceRow?; let reply: ServerMsg?; let error: String? }
struct StatusLine: Identifiable, Hashable { let id = UUID(); let text: String; let source: SourceRow? }
enum AskKoda { static let note = Notification.Name("tradster.ask") }
struct ConvRow: Codable, Identifiable, Hashable {
    let id: String; let title: String?; let created: String?; let updated: String?; let agents: [String]?; let count: Int?; let last: String?; let brief: Bool?
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
    // live, while an answer is on its way (streaming)
    @Published var statusLines: [StatusLine] = []
    @Published var streamText = ""
    var streaming: Bool { UserDefaults.standard.object(forKey: "stream") as? Bool ?? true }

    static let suggestions = ["Giv mig et dybdegående overblik over alt", "Hvad købte vi i dag?", "Hvordan står bogen lige nu?", "Hvad er lukket med gevinst?", "Hvad ligger der i noteringsbogen?", "Hvilket ben taber mest?"]

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
        if selected.isEmpty { return "Koda" }
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
        Haptic.tap()
        var payload: [String: Any] = ["message": body, "agents": Array(selected)]
        var localImage: String? = nil
        if let image, let jpeg = image.tradsterJPEG() {
            payload["image"] = jpeg.base64EncodedString()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try? jpeg.write(to: tmp); localImage = tmp.absoluteString
        }
        messages.append(ServerMsg(role: "user", text: body, at: ISO8601DateFormatter().string(from: Date()), from: nil, agent: nil, cards: nil, image: localImage, sources: nil))
        // iOS gives a backgrounded app ~30 s; the server finishes regardless and pushes if we are gone.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "koda") {}
        defer { UIApplication.shared.endBackgroundTask(bg) }
        if streaming { await stream(payload) } else { await plain(payload) }
    }

    private func plain(_ payload: [String: Any]) async {
        do {
            let (d, resp) = try await URLSession.shared.data(for: request("conversations/\(conversationId ?? "new")/message", method: "POST", body: payload, timeout: 240))
            let p = try? JSONDecoder().decode(SendResult.self, from: d)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                error = p?.error ?? "HTTP \(h.statusCode)"; Haptic.fail()
            } else if let p {
                if let id = p.id { conversationId = id }
                messages.append(contentsOf: p.replies ?? [])
                Haptic.done()
                await refreshList()
            } else {
                error = "Intet svar"
            }
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }

    /// The answer as it is written: status lines while Koda looks things up, then the text.
    private func stream(_ payload: [String: Any]) async {
        statusLines = []; streamText = ""
        var got = false
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: request("conversations/\(conversationId ?? "new")/stream", method: "POST", body: payload, timeout: 300))
            if let h = resp as? HTTPURLResponse, h.statusCode == 404 { await plain(payload); return }   // server without streaming yet
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { error = "HTTP \(h.statusCode)"; Haptic.fail() }
            else {
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let ev = try? JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8)) else { continue }
                    switch ev.type {
                    case "conv": if let id = ev.id { conversationId = id }
                    case "status": statusLines.append(StatusLine(text: ev.text ?? "", source: ev.source)); Haptic.pick()
                    case "delta":
                        if streamText.isEmpty { Haptic.soft() }
                        streamText += ev.text ?? ""
                    case "done":
                        if let r = ev.reply { messages.append(r); got = true }
                        streamText = ""; statusLines = []
                    case "error": error = ev.error ?? "Fejl"; Haptic.fail()
                    default: break
                    }
                }
            }
        } catch {
            if !got { self.error = error.localizedDescription }
        }
        if got { Haptic.done() }
        statusLines = []; streamText = ""
        sending = false
        await refreshList()
    }

    /// Back from the background: pick up an answer that finished while we were away.
    func resume() async {
        guard let id = conversationId, !sending else { return }
        if let doc = await fetch("conversations/\(id)", ConvDoc.self), (doc.messages?.count ?? 0) > messages.count {
            messages = doc.messages ?? []
        }
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
    @State private var showAgents = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var phase
    @StateObject private var dictation = Dictation()
    @State private var pressStart: Date? = nil
    @State private var holdSend = false
    @FocusState private var focused: Bool

    private let drawerWidth: CGFloat = UIScreen.main.bounds.width - 72
    @State private var drag: CGFloat = 0                     // live, while the finger is down
    private var pageOffset: CGFloat { min(drawerWidth, max(0, (showHistory ? drawerWidth : 0) + drag)) }
    private var openAmount: CGFloat { drawerWidth > 0 ? pageOffset / drawerWidth : 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            // The drawer is the floor; the page is a card lying on it that slides aside.
            Theme.bg.ignoresSafeArea()
            HistoryView(model: model, onClose: { setDrawer(false) }, onBook: { setDrawer(false); showBook = true }, onAgents: { setDrawer(false); showAgents = true }, onSettings: { setDrawer(false); showSettings = true })
                .frame(width: drawerWidth)
                .opacity(Double(0.35 + 0.65 * openAmount))
            VStack(spacing: 0) {
                topBar
                if model.messages.isEmpty { emptyState } else { thread }
                composer
            }
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 44 * openAmount, style: .continuous))
            .shadow(color: .black.opacity(0.5 * openAmount), radius: 24, x: -8, y: 0)
            .overlay {
                if pageOffset > 0 {
                    Color.black.opacity(0.25 * openAmount)
                        .onTapGesture { setDrawer(false) }
                }
            }
            .offset(x: pageOffset)
            .ignoresSafeArea(edges: openAmount > 0 ? .vertical : [])
            // The card follows the finger. From the left edge when closed, from anywhere when open;
            // high priority so the scroll views and the text field inside do not swallow it.
            .simultaneousGesture(DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onChanged { g in
                    let dx = g.translation.width, dy = g.translation.height
                    guard abs(dx) > abs(dy) * 1.5 else { return }                 // a vertical swipe is a scroll
                    if focused { focused = false }
                    if !showHistory { if g.startLocation.x < 60 { drag = max(0, dx) } }
                    else { drag = min(0, dx) }
                }
                .onEnded { g in
                    let predicted = g.predictedEndTranslation.width
                    let open: Bool
                    if !showHistory { open = g.startLocation.x < 60 && (drag > drawerWidth * 0.3 || predicted > drawerWidth * 0.5) }
                    else { open = !(drag < -drawerWidth * 0.2 || predicted < -drawerWidth * 0.5) }
                    if open != showHistory { Haptic.soft() }
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) { showHistory = open; drag = 0 }
                })
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: AskKoda.note)) { n in
            if let q = n.userInfo?["q"] as? String { Task { await model.send(q) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: PushTarget.open)) { n in
            if let id = n.userInfo?["conv"] as? String { Task { await model.open(id) } }
        }
        .sheet(isPresented: $showBook) { BookSheet(model: model) }
        .sheet(isPresented: $showAgents) { AgentsSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onChange(of: phase) { _, p in if p == .active { Task { await model.resume() } } }
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

    private func setDrawer(_ open: Bool) { Haptic.soft(); if open { focused = false }; withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) { showHistory = open; drag = 0 } }

    private func roundButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
        }
    }

    private var topBar: some View {
        HStack {
            roundButton("line.3.horizontal") { setDrawer(true) }
            Spacer()
            if !model.messages.isEmpty {
                Text(model.roomLabel).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            roundButton(model.messages.isEmpty ? "book.closed" : "square.and.pencil") {
                focused = false; if model.messages.isEmpty { showBook = true } else { withAnimation { model.newChat() } }
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
            Image("Logo").resizable().scaledToFit().frame(width: 96).padding(.bottom, 26)
            Text(greeting)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.text).multilineTextAlignment(.center).padding(.horizontal, 28)
            if let h = model.today?.headline {
                Text(h).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).padding(.top, 14).padding(.horizontal, 40)
            }
            // The open legs as a row of logos; tap it for the whole book.
            if !model.openCards.isEmpty {
                Button { showBook = true } label: {
                    HStack(spacing: 0) {
                        HStack(spacing: -9) {
                            ForEach(model.openCards.prefix(8)) { c in
                                CoinLogo(url: c.logo, fallback: c.logo_fallback, size: 30)
                                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                            }
                        }
                        if model.openCards.count > 8 {
                            Text("+\(model.openCards.count - 8)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.leading, 8)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.leading, 8)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
    }

    private var thread: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(model.messages) { m in BookBubble(m: m).id(m.id) }
                        if model.sending {
                            LiveAnswer(label: model.selected.isEmpty ? "Koda tænker" : "\(model.roomLabel) tænker",
                                       lines: model.statusLines, text: model.streamText).padding(.horizontal, 20)
                        }
                        // Room under the last question, so it can sit at the top while the answer arrives.
                        Color.clear.frame(height: model.sending ? geo.size.height * 0.75 : 1).id("bottom")
                    }.padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { focused = false }
                .onChange(of: model.messages.count) { old, new in
                    guard new > old, let last = model.messages.last else { return }
                    if last.role == "user" {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .top) }   // your question to the top
                    } else if let q = model.messages.last(where: { $0.role == "user" }) {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(q.id, anchor: .top) }      // the answer reads down from it
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.conversationId) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
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
                TextField("", text: $draft, prompt: Text(model.messages.isEmpty ? (model.selected.isEmpty ? "Spørg Koda" : "Skriv til \(model.roomLabel)") : "Skriv videre").foregroundStyle(Theme.secondary), axis: .vertical)
                    .lineLimit(1...6).focused($focused)
                    .font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.accent)
                    .padding(.horizontal, 8).padding(.top, 6)
                if dictation.listening { recordingRow } else {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.text)
                            .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
                    }
                    if !model.messages.isEmpty {
                        // The room is set when the conversation starts; mid-chat it is a label, not a choice.
                        HStack(spacing: 6) {
                            if model.selected.isEmpty { Image("Logo").resizable().scaledToFit().frame(width: 16, height: 16) }
                            else { Image(systemName: "person.2").font(.system(size: 12, weight: .semibold)) }
                            Text(model.roomLabel).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12).frame(height: 38)
                    } else {
                    Button { showAgents = true } label: {
                        HStack(spacing: 6) {
                            if model.selected.isEmpty { Image("Logo").resizable().scaledToFit().frame(width: 16, height: 16) }
                            else { Image(systemName: "person.2.fill").font(.system(size: 12, weight: .semibold)) }
                            Text(model.roomLabel).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).frame(height: 38).background(Theme.surface2, in: Capsule())
                    }
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
    /// While listening the bottom row becomes: cancel, the voice as a line that only moves
    /// when you speak, stop (keep the words to read over), send.
    var recordingRow: some View {
        HStack(spacing: 10) {
            Button { _ = dictation.stop(); draft = "" } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
            }
            WideWaveform(history: dictation.history).frame(height: 38)
            Button { draft = dictation.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
            }
            Button {
                let t = dictation.stop(); draft = ""
                if !t.isEmpty { let p = photo; photo = nil; Task { await model.send(t, image: p) } }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38).background(Theme.accent, in: Circle())
            }
        }
    }

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

/// While Koda works: what it is looking at, line by line with the source's logo, then the text
/// as it is written. Before anything has come back, the breathing mark.
struct LiveAnswer: View {
    let label: String; let lines: [StatusLine]; let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                HStack(spacing: 8) {
                    if let lg = l.source?.logo, let u = URL(string: lg) {
                        AsyncImage(url: u) { ph in if case .success(let im) = ph { im.resizable().scaledToFit() } else { Circle().fill(Theme.surface2) } }
                            .frame(width: 16, height: 16).clipShape(Circle())
                    } else {
                        Image(systemName: i == lines.count - 1 && text.isEmpty ? "magnifyingglass" : "checkmark")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary).frame(width: 16, height: 16)
                    }
                    Text(l.text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .opacity(i == lines.count - 1 && text.isEmpty ? 1 : 0.6)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if text.isEmpty { Thinking(label: lines.isEmpty ? label : "") }
            else { Text(text).font(.system(size: 16.5)).foregroundStyle(Theme.text).lineSpacing(4) }
        }
        .animation(.easeOut(duration: 0.2), value: lines.count)
    }
}

/// Settings: one switch and what Koda remembers about you.
struct SettingsSheet: View {
    @AppStorage("stream") private var stream = true
    @State private var facts: [String] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $stream) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Svar skriver sig frem").foregroundStyle(Theme.text)
                            Text("Teksten kommer mens Koda skriver, og du ser hvad den slår op.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                    }.tint(Theme.accent)
                }.listRowBackground(Theme.surface)
                Section("Hvad Koda husker om dig") {
                    if facts.isEmpty { Text("Intet endnu").foregroundStyle(Theme.secondary) }
                    ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                        Text(f).foregroundStyle(Theme.text)
                            .swipeActions { Button(role: .destructive) { Task { await forget(i) } } label: { Label("Glem", systemImage: "trash") } }
                    }
                }.listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Indstillinger").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Færdig") { dismiss() }.foregroundStyle(Theme.accent) } }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }
    /// The server's shape is read loosely: a list of strings, or of objects with a text field.
    private func load() async {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/memory")!); r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: r), let j = try? JSONSerialization.jsonObject(with: d) else { return }
        var arr: [Any] = []
        if let a = j as? [Any] { arr = a } else if let o = j as? [String: Any] { arr = (o["facts"] ?? o["memory"] ?? o["items"]) as? [Any] ?? [] }
        facts = arr.compactMap { x in (x as? String) ?? ((x as? [String: Any])?["text"] as? String) ?? ((x as? [String: Any])?["fact"] as? String) }
    }
    private func forget(_ i: Int) async {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/memory/\(i)")!); r.httpMethod = "DELETE"; r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession.shared.data(for: r); Haptic.pick(); await load()
    }
}

/// One line while the answer is on its way: the mark breathing, three words beside it.
struct Thinking: View {
    let label: String
    @State private var on = false
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("Logo").resizable().scaledToFit().frame(width: 22, height: 22)
                .scaleEffect(on ? 1.08 : 0.92).opacity(on ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            if !label.isEmpty { Text(label).font(.system(size: 15)).foregroundStyle(Theme.secondary) }
                .opacity(on ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
        }
        .onAppear { on = true }
    }
}

struct WideWaveform: View {
    let history: [CGFloat]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, v in
                Capsule().fill(Theme.text)
                    .frame(width: 2.5, height: v < 0.03 ? 2 : 2 + 24 * min(1, v))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.06), value: history)
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
    let onClose: () -> Void
    let onBook: () -> Void
    let onAgents: () -> Void
    let onSettings: () -> Void
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var rows: [ConvRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.conversations : model.conversations.filter { ($0.title ?? "").lowercased().contains(q) || ($0.last ?? "").lowercased().contains(q) }
    }
    private var groups: [(String, [ConvRow])] {
        let cal = Calendar.current
        var today: [ConvRow] = [], week: [ConvRow] = [], older: [ConvRow] = []
        for c in rows {
            let d = ISO8601DateFormatter.withFraction.date(from: c.updated ?? "") ?? ISO8601DateFormatter().date(from: c.updated ?? "") ?? .distantPast
            if cal.isDateInToday(d) { today.append(c) }
            else if d > Date().addingTimeInterval(-7 * 86400) { week.append(c) }
            else { older.append(c) }
        }
        return [("I dag", today), ("Sidste 7 dage", week), ("Ældre", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if searching {
                        TextField("", text: $query, prompt: Text("Søg i samtaler").foregroundStyle(Theme.secondary))
                            .focused($searchFocused).font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.accent)
                            .padding(.horizontal, 14).frame(height: 44).background(Theme.surface, in: Capsule())
                        Button { searching = false; query = "" } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
                        }
                    } else {
                        Text("Tradster").font(.system(size: 30, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                        Spacer()
                        Button { searching = true; searchFocused = true } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        navRow("book.closed", "Bogen lige nu", onBook)
                        navRow("person.2", "Hvem svarer?", onAgents)
                        navRow("sunrise", "Morgenbriefer") { query = "Morgenbrief"; searching = true }
                        ForEach(groups, id: \.0) { title, list in
                            Text(title).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 6)
                            ForEach(list) { c in
                                Button { Haptic.pick(); Task { await model.open(c.id); onClose() } } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: c.brief == true ? "sunrise" : ((c.agents ?? []).isEmpty ? "bubble.left" : "person.2"))
                                            .font(.system(size: 17)).foregroundStyle(Theme.secondary).frame(width: 24)
                                        Text(c.title ?? "Samtale").font(.system(size: 18)).foregroundStyle(Theme.text).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 20).padding(.vertical, 13)
                                    .background(c.id == model.conversationId ? Theme.surface : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button(role: .destructive) { Task { await model.delete(c.id) } } label: { Label("Slet", systemImage: "trash") } }
                            }
                        }
                        if rows.isEmpty {
                            Text(query.isEmpty ? "Ingen samtaler endnu" : "Intet fundet").font(.system(size: 15)).foregroundStyle(Theme.secondary).padding(20)
                        }
                        Color.clear.frame(height: 110)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            // Bottom: who you are, and the one button that matters.
            HStack {
                Button(action: onSettings) {
                    Circle().fill(Theme.surface2).frame(width: 46, height: 46)
                        .overlay(Text("M").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text))
                }
                Spacer()
                Button { model.newChat(); onClose() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        Text("Ny samtale").font(.system(size: 17, weight: .medium))
                    }
                    .foregroundStyle(Theme.bg).padding(.horizontal, 22).frame(height: 50)
                    .background(Theme.text, in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 46, height: 46)
            }
            .padding(.horizontal, 22).padding(.bottom, 14)
        }
        .task { await model.refreshList() }
    }

    private func navRow(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Theme.text).frame(width: 24)
                Text(title).font(.system(size: 19)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }.buttonStyle(.plain)
    }
}

// ---- who is in the room -------------------------------------------------------------------
// One screen for one decision: Koda alone, or which agents answer. Nothing else on it.
struct AgentsSheet: View {
    @ObservedObject var model: BookChatModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    row(selected: model.selected.isEmpty, title: "Koda", subtitle: "Firmaets egen model. Kender bogen og markedet.", icon: AnyView(Image("Logo").resizable().scaledToFit().frame(width: 26, height: 26))) {
                        model.selected = []
                    }
                    Text("ELLER INVITÉR AGENTER").font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14).padding(.bottom, 2).padding(.horizontal, 4)
                    ForEach(model.agents) { a in
                        let on = model.selected.contains(a.id)
                        row(selected: on, title: a.name ?? a.id, subtitle: a.role ?? "", icon: AnyView(initial(a.name ?? a.id))) {
                            if on { model.selected.remove(a.id) } else { model.selected.insert(a.id) }
                        }
                    }
                    Text("Vælg flere, så svarer de hver for sig på samme besked.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.horizontal, 4)
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Hvem svarer?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Færdig") { dismiss() }.font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent) } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }
    private func initial(_ name: String) -> some View {
        Circle().fill(Theme.surface2).frame(width: 36, height: 36)
            .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text))
    }
    private func row(selected: Bool, title: String, subtitle: String, icon: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.pick(); action() }) {
            HStack(spacing: 12) {
                icon.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(selected ? Theme.accent : Theme.secondary.opacity(0.5))
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 1))
        }.buttonStyle(.plain)
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
                    if !model.openCards.isEmpty { CardStrip(cards: model.openCards).padding(.horizontal, -20) }
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
            // Plain text, full width, no mark in front of it: the answer is the thing. An agent's
            // reply carries its name above, so a room with several voices stays readable.
            VStack(alignment: .leading, spacing: 10) {
                if let f = m.from, m.agent != nil {
                    Text(f.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.accent)
                }
                Text(m.text ?? "").font(.system(size: 16.5)).foregroundStyle(Theme.text).lineSpacing(4).textSelection(.enabled)
                if let cs = m.cards, !cs.isEmpty { CardStrip(cards: cs).padding(.top, 2).padding(.horizontal, -20) }
                if let src = m.sources, !src.isEmpty { Sources(items: src) }
            }.padding(.horizontal, 20)
        }
    }
}

/// Answers no longer arrive as a wall of charts. One card shows in full; several become a row
/// of tiles to swipe through, each with logo, ticker, bp and a tiny line. Tap one to open it.
struct CardStrip: View {
    let cards: [BookCard]
    @State private var open: BookCard? = nil
    var body: some View {
        Group {
            if cards.count == 1 {
                Button { Haptic.tap(); open = cards[0] } label: { CoinCard(c: cards[0]) }.buttonStyle(.plain).padding(.horizontal, 20)
            } else if cards.count >= 6 {
                BookMap(cards: cards) { Haptic.tap(); open = $0 }.padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(cards) { c in Button { Haptic.tap(); open = c } label: { Tile(c: c) }.buttonStyle(.plain) }
                    }.padding(.horizontal, 20)
                }
            }
        }
        .sheet(item: $open) { c in LegDetail(c: c) }
    }
}

/// The whole book at a glance: every leg as a square with its logo, coloured by how it is doing
/// (deeper colour = bigger move), longs and shorts side by side with their average.
struct BookMap: View {
    let cards: [BookCard]
    let tap: (BookCard) -> Void
    private var maxAbs: Double { max(1, cards.map { abs(Double($0.isMarket ? Int(($0.change_pct ?? 0) * 100) : ($0.bp ?? 0))) }.max() ?? 1) }
    var body: some View {
        let longs = cards.filter { $0.side == "long" }.sorted { ($0.bp ?? 0) > ($1.bp ?? 0) }
        let shorts = cards.filter { $0.side == "short" }.sorted { ($0.bp ?? 0) > ($1.bp ?? 0) }
        let other = cards.filter { $0.side != "long" && $0.side != "short" }
        VStack(alignment: .leading, spacing: 14) {
            if !longs.isEmpty { section("LANGE", longs) }
            if !shorts.isEmpty { section("KORTE", shorts) }
            if !other.isEmpty { section("ANDET", other) }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
    private func section(_ title: String, _ list: [BookCard]) -> some View {
        let avg = list.isEmpty ? 0 : Double(list.map { $0.bp ?? 0 }.reduce(0, +)) / Double(list.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.secondary)
                Spacer()
                Text(String(format: "snit %+.0f bp", avg)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(avg >= 0 ? Theme.up : Theme.down)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(list) { c in
                    let bp = Double(c.bp ?? 0)
                    let strength = min(1, abs(bp) / maxAbs)
                    Button { tap(c) } label: {
                        VStack(spacing: 4) {
                            CoinLogo(url: c.logo, fallback: c.logo_fallback, size: 28)
                            Text(c.symbol ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(bp >= 0 ? "+\(Int(bp))" : "\(Int(bp))").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background((bp >= 0 ? Theme.up : Theme.down).opacity(0.10 + 0.45 * strength), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// Small, under the answer: where the numbers came from.
struct Sources: View {
    let items: [SourceRow]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Kilder").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).padding(.trailing, 2)
                ForEach(items, id: \.self) { src in
                    chip(src)
                }
            }
        }
    }
    @ViewBuilder private func chip(_ src: SourceRow) -> some View {
        if let u = src.url, let url = URL(string: u) { Link(destination: url) { pill(src) } } else { pill(src) }
    }
    private func pill(_ src: SourceRow) -> some View {
                    HStack(spacing: 5) {
                        if let l = src.logo, let u = URL(string: l) {
                            AsyncImage(url: u) { ph in if case .success(let i) = ph { i.resizable().scaledToFit() } else { icon(src.kind) } }
                                .frame(width: 14, height: 14).clipShape(Circle())
                        } else { icon(src.kind) }
                        Text(src.name ?? src.symbol ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(1)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
    private func icon(_ kind: String?) -> some View {
        Image(systemName: kind == "market" ? "chart.xyaxis.line" : kind == "ledger" ? "clock.arrow.circlepath" : kind == "web" ? "globe" : kind == "memory" ? "brain" : "book.closed")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).frame(width: 14, height: 14)
    }
}

/// Tap a coin and you get the whole story of that leg, not a bigger copy of the card.
struct LegDetail: View {
    let c: BookCard
    @Environment(\.dismiss) private var dismiss
    private var bpVal: Double { c.isMarket ? (c.change_pct ?? 0) * 100 : Double(c.bp ?? 0) }
    private var tint: Color { bpVal >= 0 ? Theme.up : Theme.down }
    private func px(_ v: Double) -> String { v >= 100 ? String(format: "%.2f", v) : v >= 1 ? String(format: "%.4f", v) : String(format: "%.6g", v) }
    private func date(_ s: String?) -> Date? { guard let s else { return nil }; return ISO8601DateFormatter().date(from: s) ?? ISO8601DateFormatter.withFraction.date(from: s) }
    private func until(_ s: String?) -> String {
        guard let d = date(s) else { return "–" }
        let m = Int(d.timeIntervalSinceNow / 60); if m <= 0 { return "nu" }
        return m >= 1440 ? "om \(m / 1440) d \((m % 1440) / 60) t" : "om \(m / 60) t \(m % 60) m"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        if c.isMarket {
                            Circle().fill(Theme.surface2).frame(width: 52, height: 52).overlay(Image(systemName: "chart.xyaxis.line").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text))
                        } else { CoinLogo(url: c.logo, fallback: c.logo_fallback, size: 52) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name ?? c.symbol ?? "").font(.system(size: 24, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                            HStack(spacing: 6) {
                                Text(c.symbol ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                                if let side = c.side {
                                    Text(side == "short" ? "SHORT" : "LONG").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background((side == "short" ? Theme.down : Theme.up).opacity(0.18), in: Capsule()).foregroundStyle(side == "short" ? Theme.down : Theme.up)
                                }
                            }
                        }
                    }
                    Text(c.isMarket ? String(format: "%+.2f %%", c.change_pct ?? 0) : String(format: "%+.0f bp", bpVal))
                        .font(.system(size: 44, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
                    + Text(c.isMarket ? "  mod luk i går" : String(format: "  (%+.2f %%)", bpVal / 100)).font(.system(size: 15)).foregroundStyle(Theme.secondary)

                    if let s = c.series, s.count > 2 {
                        let ref = c.isMarket ? (c.prev_close ?? s[0].c) : (c.entry ?? s[0].c)
                        let vals = s.map(\.c) + [ref] + (c.stop.map { [$0] } ?? [])
                        let lo = vals.min() ?? 0, hi = vals.max() ?? 1, pad = max((hi - lo) * 0.08, 1e-9)
                        Chart {
                            ForEach(Array(s.enumerated()), id: \.offset) { _, p in
                                AreaMark(x: .value("t", Date(timeIntervalSince1970: p.t)), yStart: .value("lo", lo - pad), yEnd: .value("v", p.c))
                                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("t", Date(timeIntervalSince1970: p.t)), y: .value("v", p.c)).foregroundStyle(tint).lineStyle(.init(lineWidth: 2.4, lineCap: .round))
                            }
                            RuleMark(y: .value("ref", ref)).foregroundStyle(Theme.secondary.opacity(0.7)).lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                                .annotation(position: .top, alignment: .leading) { Text(c.isMarket ? "luk i går" : "indgang").font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                            if let st = c.stop {
                                RuleMark(y: .value("stop", st)).foregroundStyle(Theme.down.opacity(0.7)).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
                                    .annotation(position: .top, alignment: .trailing) { Text("stop").font(.system(size: 10)).foregroundStyle(Theme.down) }
                            }
                        }
                        .chartYScale(domain: (lo - pad)...(hi + pad))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.secondary) } }
                        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.secondary) } }
                        .frame(height: 240)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(stats, id: \.0) { k, v in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(k.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.secondary)
                                Text(v).font(.system(size: 17, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    Button {
                        Haptic.tap(); dismiss()
                        let q = c.isMarket ? "Giv mig et dybdegående overblik over \(c.name ?? c.symbol ?? "")" : "Giv mig et dybdegående overblik over \(c.name ?? "") (\(c.symbol ?? "")) i bogen"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NotificationCenter.default.post(name: AskKoda.note, object: nil, userInfo: ["q": q]) }
                    } label: {
                        HStack(spacing: 8) {
                            Image("Logo").resizable().scaledToFit().frame(width: 20, height: 20)
                            Text("Spørg Koda om \(c.symbol ?? "den")").font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(Theme.bg).frame(maxWidth: .infinity).frame(height: 50)
                        .background(Theme.text, in: Capsule())
                    }
                }.padding(20)
            }
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.secondary).frame(width: 30, height: 30).background(Theme.surface2, in: Circle()) } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
    private var stats: [(String, String)] {
        if c.isMarket {
            let today = (c.series ?? []).filter { $0.t >= (c.day_start ?? 0) }.map(\.c)
            return [("Sidst", c.last.map(px) ?? "–"), ("Luk i går", c.prev_close.map(px) ?? "–"),
                    ("Dagens høj", today.max().map(px) ?? "–"), ("Dagens lav", today.min().map(px) ?? "–")]
        }
        var out: [(String, String)] = [("Indgang", c.entry.map(px) ?? "–"), ("Nu", (c.mark ?? c.exit).map(px) ?? "–")]
        if c.status == "closed" { out += [("Lukket", c.why ?? "–"), ("Resultat", c.dkk.map { String(format: "%+.0f kr", $0) } ?? "–")] }
        else { out += [("Åbnet", Tradster.when(c.opened_at)), ("Lukker", until(c.closes_at))] }
        if let st = c.stop, let m = c.mark { out += [("Stop", px(st)), ("Til stop", String(format: "%.1f %%", (st / m - 1) * 100))] }
        out.append(("Bog", c.book == "listing" ? "Noteringsbogen" : "Momentum-kurven"))
        return out
    }
}

struct Tile: View {
    let c: BookCard
    private var tint: Color { ((c.isMarket ? (c.change_pct ?? 0) : Double(c.bp ?? 0))) >= 0 ? Theme.up : Theme.down }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if c.isMarket {
                    Circle().fill(Theme.surface2).frame(width: 26, height: 26)
                        .overlay(Image(systemName: "chart.xyaxis.line").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text))
                } else { CoinLogo(url: c.logo, fallback: c.logo_fallback, size: 26) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.symbol ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(c.isMarket ? "marked" : (c.side == "short" ? "short" : "long")).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            if let s = c.series, s.count > 2 {
                let v = s.map(\.c); let lo = v.min() ?? 0, hi = v.max() ?? 1
                Chart(Array(v.enumerated()), id: \.offset) { i, y in
                    LineMark(x: .value("i", i), y: .value("v", y)).foregroundStyle(tint).lineStyle(.init(lineWidth: 1.6, lineCap: .round))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: lo...(hi > lo ? hi : lo + 1e-9))
                .frame(height: 26)
            } else { Spacer().frame(height: 26) }
            Text(c.isMarket ? String(format: "%+.2f %%", c.change_pct ?? 0) : ((c.bp ?? 0) >= 0 ? "+\(c.bp ?? 0) bp" : "\(c.bp ?? 0) bp"))
                .font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(tint)
        }
        .padding(12).frame(width: 118, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
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
        if c.isMarket { market } else { leg }
    }

    /// Yesterday against today: the last two sessions, a dashed line at yesterday's close, a
    /// thin line where today began. The change is against yesterday's close.
    private var market: some View {
        let pct = c.change_pct ?? 0
        let col: Color = pct >= 0 ? Theme.up : Theme.down
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(Theme.surface2).frame(width: 36, height: 36)
                    .overlay(Image(systemName: "chart.xyaxis.line").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name ?? c.symbol ?? "").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(c.symbol ?? "") · i går → i dag").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%@%.2f %%", pct >= 0 ? "+" : "", pct)).font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(col)
                    if let l = c.last, let pc = c.prev_close {
                        Text("\(px(pc)) → \(px(l))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                }
            }
            if let s = c.series, s.count > 2 {
                let vals = s.map(\.c) + [c.prev_close ?? s[0].c]
                let lo = vals.min() ?? 0, hi = vals.max() ?? 1, pad = max((hi - lo) * 0.1, 1e-9)
                Chart {
                    ForEach(Array(s.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("t", Date(timeIntervalSince1970: p.t)), yStart: .value("lo", lo - pad), yEnd: .value("kurs", p.c))
                            .foregroundStyle(LinearGradient(colors: [col.opacity(0.22), col.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", Date(timeIntervalSince1970: p.t)), y: .value("kurs", p.c))
                            .foregroundStyle(col).lineStyle(.init(lineWidth: 2, lineCap: .round))
                    }
                    if let pc = c.prev_close {
                        RuleMark(y: .value("luk i går", pc)).foregroundStyle(Theme.secondary.opacity(0.6)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading) { Text("luk i går \(px(pc))").font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                    }
                    if let d = c.day_start {
                        RuleMark(x: .value("i dag", Date(timeIntervalSince1970: d))).foregroundStyle(Theme.secondary.opacity(0.35)).lineStyle(.init(lineWidth: 1))
                            .annotation(position: .bottom, alignment: .leading) { Text("i dag").font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9)).foregroundStyle(Theme.secondary) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().font(.system(size: 9)).foregroundStyle(Theme.secondary) } }
                .frame(height: 120)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private var leg: some View {
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

// ---- haptics: small, and only where something actually happened ------------------------
enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8) }
    static func pick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func fail() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
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
