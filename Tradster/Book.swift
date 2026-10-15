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

struct BookPt: Codable, Hashable, Sendable { let t: Double; let c: Double }
struct BookCard: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(book ?? "")/\(symbol ?? "")/\(status ?? "")/\(opened_at ?? "")" }
    let symbol: String?; let name: String?; let logo: String?; let logo_fallback: String?
    let book: String?; let side: String?; let status: String?
    let entry: Double?; let mark: Double?; let exit: Double?; let bp: Int?; let stop: Double?; let dkk: Double?
    let opened_at: String?; let closes_at: String?; let closed_at: String?; let why: String?; let note: String?
    let today: Bool?; let series: [BookPt]?
    let kind: String?; let last: Double?; let change_pct: Double?; let prev_close: Double?; let currency: String?; let day_start: Double?; let status_text: String?
    var isMarket: Bool { kind == "market" }
}
struct BookToday: Codable, Sendable {
    let at: String?; let headline: String?; let cards: [BookCard]?
    var equity: [String: BookEquity?]? = nil
    /// Both paper books together: what they are worth now, and against what they started with.
    var total: (now: Double, start: Double)? {
        let rows = (equity ?? [:]).values.compactMap { $0 }.filter { $0.dkk != nil && $0.start != nil }
        guard !rows.isEmpty else { return nil }
        return (rows.reduce(0) { $0 + ($1.dkk ?? 0) }, rows.reduce(0) { $0 + ($1.start ?? 0) })
    }
}
struct BookEquity: Codable, Hashable, Sendable { let dkk: Double?; let start: Double? }
struct AgentRow: Codable, Identifiable, Hashable, Sendable { let id: String; let name: String?; let role: String? }
struct AgentsPayload: Codable, Sendable { let agents: [AgentRow]? }
struct ServerMsg: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(at ?? "")/\(role ?? "")/\(from ?? "")/\((text ?? "").prefix(20))" }
    let role: String?; let text: String?; let at: String?; let from: String?; let agent: String?
    let cards: [BookCard]?; let image: String?
    var sources: [SourceRow]? = nil
    // From Analyse and Udfør: what Koda thought (and for how long), the steps it took, and tables or
    // charts it made. All optional; an older server simply leaves them out.
    var thinking: String? = nil
    var thinking_s: Double? = nil
    var steps: [Step]? = nil
    var artifacts: [Artifact]? = nil
    enum CodingKeys: String, CodingKey { case role, text, at, from, agent, cards, image, sources, thinking, thinking_s, steps, artifacts }
}
/// Read loosely: one odd field must never cost the whole conversation. Before this, a reply the
/// phone could not decode made the conversation fail to open at all.
extension ServerMsg {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ t: T.Type, _ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        role = opt(String.self, .role); text = opt(String.self, .text); at = opt(String.self, .at)
        from = opt(String.self, .from); agent = opt(String.self, .agent); image = opt(String.self, .image)
        cards = opt([Lossy<BookCard>].self, .cards)?.compactMap(\.value)
        sources = opt([Lossy<SourceRow>].self, .sources)?.compactMap(\.value)
        thinking = opt(String.self, .thinking)
        thinking_s = opt(Double.self, .thinking_s)
        steps = opt([Lossy<Step>].self, .steps)?.compactMap(\.value)
        artifacts = opt([Lossy<Artifact>].self, .artifacts)?.compactMap(\.value)
    }
}
/// An element that failed to decode becomes nil instead of failing the array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}
/// A JSON scalar as text: tables arrive with numbers and strings mixed.
struct Cell: Decodable {
    let text: String
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { text = "" }
        else if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let x = try? c.decode(Double.self) { text = Cell.num(x) }
        else if let b = try? c.decode(Bool.self) { text = b ? "ja" : "nej" }
        else { text = "" }
    }
    static func num(_ x: Double) -> String {
        let a = abs(x)
        return a >= 1000 ? String(format: "%.0f", x) : a >= 1 ? String(format: "%.2f", x) : a == 0 ? "0" : String(format: "%.4g", x)
    }
}
struct Step: Codable, Hashable, Sendable {
    var title: String?; var detail: String?; var ok: Bool?; var status: String?
    var failed: Bool { ok == false || ["failed", "error", "fejl"].contains(status ?? "") }
    enum CodingKeys: String, CodingKey { case title, detail, ok, status }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(Cell.self, forKey: .title))??.text
        detail = (try? c.decodeIfPresent(Cell.self, forKey: .detail))??.text
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
    }
}
struct ArtPt: Codable, Hashable, Sendable {
    var t: Double?; var label: String?; var v: Double
    enum CodingKeys: String, CodingKey { case t, label, v }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let x = (try? c.decodeIfPresent(Double.self, forKey: .v)) ?? nil { v = x }
        else if let s = (try? c.decodeIfPresent(String.self, forKey: .v)) ?? nil, let x = Double(s.replacingOccurrences(of: ",", with: ".")) { v = x }
        else { throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "no value") }
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        if let x = (try? c.decodeIfPresent(Double.self, forKey: .t)) ?? nil { t = x > 1e11 ? x / 1000 : x }     // seconds or ms
        else if let s = (try? c.decodeIfPresent(String.self, forKey: .t)) ?? nil {
            if let dt = Tradster.date(s) ?? Tradster.day(s) { t = dt.timeIntervalSince1970 } else { t = nil; if label == nil { label = s } }
        } else { t = nil }
    }
}
struct Artifact: Codable, Hashable, Sendable {
    var kind: String?; var title: String?; var columns: [String]?; var rows: [[String]]?; var series: [ArtPt]?; var text: String?
    enum CodingKeys: String, CodingKey { case kind, title, columns, rows, series, text }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        title = (try? c.decodeIfPresent(Cell.self, forKey: .title))??.text
        columns = (try? c.decodeIfPresent([Cell].self, forKey: .columns))??.map(\.text)
        rows = (try? c.decodeIfPresent([Lossy<[Cell]>].self, forKey: .rows))??.compactMap { $0.value?.map(\.text) }
        series = (try? c.decodeIfPresent([Lossy<ArtPt>].self, forKey: .series))??.compactMap(\.value)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
    }
}
struct SourceRow: Codable, Hashable, Sendable { let kind: String?; let name: String?; let symbol: String?; let logo: String?; var url: String? = nil }
struct StreamEvent: Codable, Sendable { let type: String; let id: String?; let title: String?; let text: String?; let source: SourceRow?; let reply: ServerMsg?; let error: String? }
struct StatusLine: Identifiable, Hashable { let id = UUID(); let text: String; let source: SourceRow? }
enum AskKoda { static let note = Notification.Name("tradster.ask") }
struct ConvRow: Codable, Identifiable, Hashable, Sendable {
    let id: String; let title: String?; let created: String?; let updated: String?; let agents: [String]?; let count: Int?; let last: String?; let brief: Bool?
}
struct ConvList: Codable, Sendable { let conversations: [ConvRow]? }
struct ConvDoc: Codable, Sendable { let id: String; let title: String?; let agents: [String]?; let messages: [ServerMsg]?; let pending: Bool?; var mode: String? = nil }
struct SendResult: Codable, Sendable { let id: String?; let title: String?; let agents: [String]?; let replies: [ServerMsg]?; let error: String? }

/// What the phone keeps between launches, so the app opens on what you saw last instead of a
/// spinner: the conversation list, the book's today, and every conversation you have opened.
enum Disk {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tradster", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// Writes happen on one serial queue, off the main thread: a conversation with its cards and
    /// price series is easily a few hundred kB of JSON, and encoding it on main dropped frames
    /// right as an answer landed. Serial, so a save and the prune after it keep their order.
    static let queue = DispatchQueue(label: "tradster.disk", qos: .utility)
    static func save<T: Encodable & Sendable>(_ v: T, _ name: String) {
        queue.async { if let d = try? JSONEncoder().encode(v) { try? d.write(to: dir.appendingPathComponent(name), options: .atomic) } }
    }
    /// Read and decode off the main thread.
    static func loadAsync<T: Decodable & Sendable>(_ t: T.Type, _ name: String) async -> T? {
        await Task.detached(priority: .userInitiated) { load(t, name) }.value
    }
    static func load<T: Decodable>(_ t: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    static func remove(_ name: String) { queue.async { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) } }
    /// Keep the newest `keep` conversations; the rest are on the server anyway.
    static func prune(keep: Int = 40) { queue.async { pruneNow(keep: keep) } }
    private static func pruneNow(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let convs = files.filter { $0.lastPathComponent.hasPrefix("conv-") }
        guard convs.count > keep else { return }
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for u in convs.sorted(by: { date($0) > date($1) }).dropFirst(keep) { try? fm.removeItem(at: u) }
    }
}
struct LastOpen: Codable, Sendable { let id: String; let at: Date }

@MainActor final class BookChatModel: ObservableObject {
    @Published var messages: [ServerMsg] = []
    @Published var conversationId: String? = nil
    @Published var conversations: [ConvRow] = []
    @Published var agents: [AgentRow] = []
    @Published var selected: Set<String> = []
    @Published var sending = false
    @Published var error: String? = nil           // one quiet line above the composer, never an alert
    @Published var offline = false                // the last call could not reach the server
    @Published var retry: String? = nil           // a question that did not get an answer, to send again
    @Published var today: BookToday? = nil
    /// How Koda answers in this conversation: "fast", "analyse" or "execute". Kept per conversation
    /// on the phone and sent with every message; a server that does not know it just ignores it.
    @Published var mode = "fast"
    /// The answer while it is being written. Its own object, not @Published here: every token used
    /// to change the model, and so re-render everything that watches it (the thread, the composer,
    /// the drawer's list) 30-60 times a second. Only LiveAnswer watches this.
    let live = LiveFeed()
    var streaming: Bool { UserDefaults.standard.object(forKey: "stream") as? Bool ?? true }
    /// What the line above the composer says, if anything.
    var quiet: String? { error ?? (offline ? "Ingen forbindelse" : nil) }

    static let suggestions = ["Giv mig et dybdegående overblik over alt", "Hvad købte vi i dag?", "Hvordan står bogen lige nu?", "Hvad er lukket med gevinst?", "Hvad ligger der i noteringsbogen?", "Hvilket ben taber mest?"]

    init() {
        conversations = Disk.load([ConvRow].self, "conversations.json") ?? []
        today = Disk.load(BookToday.self, "today.json")
        // Back within the hour (iOS ended the app meanwhile): you are where you were.
        if let l = Disk.load(LastOpen.self, "last.json"), Date().timeIntervalSince(l.at) < 3600,
           let doc = Disk.load(ConvDoc.self, "conv-\(l.id).json") { show(doc) }
    }

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
    private func fetch<T: Decodable & Sendable>(_ path: String, _ type: T.Type) async -> T? {
        do {
            let (d, _) = try await URLSession.shared.data(for: request(path))
            offline = false
            return await Self.decode(T.self, d)
        } catch {
            if Self.isOffline(error) { offline = true }
            return nil
        }
    }
    /// JSON is decoded off the main thread: a conversation with cards and series is big enough to
    /// cost a frame or two, and it always arrived at the moment the screen was changing.
    nonisolated static func decode<T: Decodable & Sendable>(_ t: T.Type, _ d: Data) async -> T? {
        await Task.detached(priority: .userInitiated) { try? JSONDecoder().decode(T.self, from: d) }.value
    }
    static func isOffline(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                                      .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed]
        return codes.contains(u.code)
    }
    /// A failure, said quietly and in Danish.
    private func say(_ e: Error) {
        if Self.isOffline(e) { offline = true; error = nil } else { error = "Kunne ikke svare" }
    }

    func bootstrap() async {
        async let t: BookToday? = fetch("today", BookToday.self)
        async let a: AgentsPayload? = fetch("agents", AgentsPayload.self)
        async let c: ConvList? = fetch("conversations", ConvList.self)
        if let v = await t { today = v; Disk.save(v, "today.json") }
        if let v = await a?.agents { agents = v }
        if let v = await c?.conversations { conversations = v; Disk.save(v, "conversations.json") }
        await resume()
    }
    func refreshToday() async { if let v = await fetch("today", BookToday.self) { today = v; Disk.save(v, "today.json") } }
    func refreshList() async {
        if let v = await fetch("conversations", ConvList.self)?.conversations { conversations = v; Disk.save(v, "conversations.json") }
    }

    var openCards: [BookCard] { (today?.cards ?? []).filter { $0.status == "open" } }
    var roomLabel: String {
        if selected.isEmpty { return "Koda" }
        let names = agents.filter { selected.contains($0.id) }.map { $0.name ?? $0.id }
        return names.count > 2 ? "\(names[0]), \(names[1]) +\(names.count - 2)" : names.joined(separator: ", ")
    }

    // Bumped whenever the screen changes conversation. An answer still on its way checks it before
    // it touches anything, so a reply can never land in the conversation you switched to.
    private var gen = 0
    private var inflight: Task<Void, Never>? = nil
    private var asked = ""

    private func show(_ doc: ConvDoc) {
        conversationId = doc.id
        messages = doc.messages ?? []
        selected = Set(doc.agents ?? [])
        mode = Self.savedModes[doc.id] ?? doc.mode.flatMap { m in Self.modes.contains { $0.id == m } ? m : nil } ?? "fast"
    }

    // ---- modes: one pill, one tap to the next ----
    struct Mode { let id: String; let label: String; let icon: String; let hint: String }
    static let modes = [Mode(id: "fast", label: "Hurtig", icon: "bolt", hint: "Kort svar med det samme"),
                        Mode(id: "analyse", label: "Analyse", icon: "chart.bar.xaxis", hint: "Tænker sig om, regner og viser tabeller"),
                        Mode(id: "execute", label: "Udfør", icon: "checklist", hint: "Gør det, trin for trin")]
    static func modeInfo(_ id: String) -> Mode { modes.first { $0.id == id } ?? modes[0] }
    private static var savedModes: [String: String] { UserDefaults.standard.dictionary(forKey: "modes") as? [String: String] ?? [:] }
    func setMode(_ m: String) { mode = m; saveMode() }
    func cycleMode() {
        let i = Self.modes.firstIndex { $0.id == mode } ?? 0
        setMode(Self.modes[(i + 1) % Self.modes.count].id)
    }
    private func saveMode() {
        guard let id = conversationId else { return }
        var d = Self.savedModes
        if mode == "fast" { d[id] = nil } else { d[id] = mode }
        UserDefaults.standard.set(d, forKey: "modes")
    }
    /// The open conversation, on disk, so it opens instantly next time.
    private func persist() {
        guard let id = conversationId, !messages.isEmpty else { return }
        Disk.save(ConvDoc(id: id, title: nil, agents: Array(selected), messages: messages, pending: nil), "conv-\(id).json")
        Disk.save(LastOpen(id: id, at: Date()), "last.json")
        Disk.prune()
    }

    func open(_ id: String) async {
        if id == conversationId, sending { return }          // already here, the answer is on its way
        leave()
        let g = gen
        if let cached = await Disk.loadAsync(ConvDoc.self, "conv-\(id).json"), g == gen { show(cached) }   // at once, from disk
        guard let doc = await fetch("conversations/\(id)", ConvDoc.self), g == gen else { return }
        show(doc); persist()
        if doc.pending == true { watch(g) }
    }
    func newChat() { leave(); conversationId = nil; messages = []; selected = []; mode = "fast"; Disk.remove("last.json") }
    /// Stop listening to the answer in flight. The server finishes it regardless; it is there
    /// when you come back to that conversation.
    private func leave() {
        gen += 1
        inflight?.cancel(); inflight = nil
        sending = false; live.reset()
        error = nil; retry = nil
    }
    func delete(_ id: String) async {
        withAnimation { conversations.removeAll { $0.id == id } }
        Disk.remove("conv-\(id).json")
        _ = try? await URLSession.shared.data(for: request("conversations/\(id)", method: "DELETE"))
        if conversationId == id { newChat() }
        await refreshList()
    }

    func send(_ text: String, image: UIImage? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || image != nil, !sending else { return }
        sending = true
        error = nil; retry = nil
        asked = body
        let g = gen
        Haptic.tap()
        var payload: [String: Any] = ["message": body, "agents": Array(selected), "mode": mode]
        var localImage: String? = nil
        if let image, let jpeg = image.tradsterJPEG() {
            payload["image"] = jpeg.base64EncodedString()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try? jpeg.write(to: tmp); localImage = tmp.absoluteString
        }
        messages.append(ServerMsg(role: "user", text: body, at: ISO8601DateFormatter.withFraction.string(from: Date()), from: nil, agent: nil, cards: nil, image: localImage, sources: nil))
        let useStream = streaming
        inflight = Task {
            // iOS gives a backgrounded app ~30 s; the server finishes regardless and pushes if we are gone.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "koda") {}
            defer { UIApplication.shared.endBackgroundTask(bg) }
            if useStream { await stream(payload, g) } else { await plain(payload, g) }
            if g == gen { inflight = nil }
        }
    }
    /// "Prøv igen" on the quiet line: send the question that got no answer, or just reconnect.
    func retryNow() {
        error = nil
        if let q = retry, !sending {
            retry = nil
            if let last = messages.last, last.role == "user", last.text == q { messages.removeLast() }
            send(q)
        } else {
            Task { await bootstrap() }
        }
    }

    private func plain(_ payload: [String: Any], _ g: Int) async {
        do {
            let (d, resp) = try await URLSession.shared.data(for: request("conversations/\(conversationId ?? "new")/message", method: "POST", body: payload, timeout: 240))
            guard g == gen else { return }
            offline = false
            let p = await Self.decode(SendResult.self, d)
            guard g == gen else { return }
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                error = p?.error ?? "Serveren svarede ikke (\(h.statusCode))"; retry = asked; Haptic.fail()
            } else if let p {
                if let id = p.id { conversationId = id; saveMode() }
                messages.append(contentsOf: p.replies ?? [])
                Haptic.done()
                persist()
                await refreshList()
            } else {
                error = "Intet svar"; retry = asked
            }
        } catch {
            guard g == gen else { return }
            if !Task.isCancelled { say(error); retry = asked; Haptic.fail() }
        }
        guard g == gen else { return }
        sending = false
    }

    /// The answer as it is written: status lines while Koda looks things up, then the text.
    private func stream(_ payload: [String: Any], _ g: Int) async {
        live.reset()
        var got = false, broke = false
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: request("conversations/\(conversationId ?? "new")/stream", method: "POST", body: payload, timeout: 300))
            guard g == gen else { return }
            offline = false
            if let h = resp as? HTTPURLResponse, h.statusCode == 404 { await plain(payload, g); return }   // server without streaming yet
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { error = "Serveren svarede ikke (\(h.statusCode))"; retry = asked; Haptic.fail() }
            else {
                for try await line in bytes.lines {
                    guard g == gen else { return }
                    guard line.hasPrefix("data:") else { continue }
                    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let ev = try? JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8)) else { continue }
                    switch ev.type {
                    case "conv": if let id = ev.id { conversationId = id; saveMode() }
                    case "status": live.status(StatusLine(text: ev.text ?? "", source: ev.source)); Haptic.pick()
                    case "thinking": live.think(ev.text ?? "")
                    case "delta":
                        if !live.hasText { Haptic.soft() }
                        live.delta(ev.text ?? "")
                    case "done":
                        if var r = ev.reply {
                            // The reasoning stays with the answer: the server's summary if it sent one,
                            // otherwise what streamed; and how long it took, measured here.
                            live.flush()
                            if (r.thinking ?? "").isEmpty, !live.thinking.isEmpty { r.thinking = live.thinking }
                            if r.thinking_s == nil, !(r.thinking ?? "").isEmpty, let sec = live.thinkSeconds { r.thinking_s = sec }
                            messages.append(r); got = true
                        }
                        live.reset()
                    case "error": error = ev.error ?? "Kunne ikke svare"; retry = asked; Haptic.fail()
                    default: break
                    }
                }
                if !got && error == nil { broke = true }          // the line closed before the answer
            }
        } catch {
            guard g == gen else { return }
            if !got, !Task.isCancelled { broke = true; if Self.isOffline(error) { offline = true } }
        }
        guard g == gen else { return }
        if broke {
            // The connection broke, not the answer: the server keeps writing. Fetch it from there.
            live.reset()
            await follow(g, question: asked)
            guard g == gen else { return }
        }
        if got { Haptic.done(); offline = false }
        live.reset()
        sending = false
        persist()
        await refreshList()
    }

    /// Poll the conversation until the answer is there or the server says it is not coming.
    private func follow(_ g: Int, question: String?) async {
        guard let id = conversationId else { if let question { retry = question; error = error ?? "Svaret kom ikke igennem" }; return }
        let have = messages.count
        for _ in 0..<60 {
            guard g == gen else { return }
            if let doc = await fetch("conversations/\(id)", ConvDoc.self) {
                guard g == gen else { return }
                let ms = doc.messages ?? []
                if ms.count >= have, let last = ms.last, last.role != "user" { messages = ms; persist(); Haptic.done(); return }
                if doc.pending != true { break }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        guard g == gen else { return }
        if let question { retry = question; if !offline { error = error ?? "Svaret kom ikke igennem" } }
    }
    /// The server is still writing in this conversation (we left mid-answer): show it working.
    private func watch(_ g: Int) {
        guard !sending else { return }
        sending = true
        inflight = Task {
            await follow(g, question: nil)
            if g == gen { sending = false; inflight = nil }
        }
    }

    /// Back from the background: pick up an answer that finished while we were away.
    func resume() async {
        guard let id = conversationId, !sending else { return }
        let g = gen
        guard let doc = await fetch("conversations/\(id)", ConvDoc.self), g == gen, !sending else { return }
        if (doc.messages?.count ?? 0) > messages.count { messages = doc.messages ?? []; persist() }
        if doc.pending == true { watch(g) }
    }
}

// ---- the one screen ---------------------------------------------------------------------
struct BookChatView: View {
    @ObservedObject var model: BookChatModel
    @State private var showBook = false
    @State private var showAgents = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var phase
    // Not observed here either: the screen does not re-render as you type.
    @State private var box = ComposerBox()

    // Held in @State, not @StateObject: this view must not re-render when the drawer moves. Only
    // the two small modifiers below watch it.
    @State private var drawer = DrawerState()

    var body: some View {
        ZStack(alignment: .leading) {
            // The drawer is the floor; the page is a card lying on it that slides aside.
            Theme.bg.ignoresSafeArea()
            HistoryView(model: model, onClose: { setDrawer(false) }, onBook: { setDrawer(false); showBook = true }, onAgents: { setDrawer(false); showAgents = true }, onSettings: { setDrawer(false); showSettings = true })
                .frame(width: drawer.width)
                .modifier(DrawerFloor(d: drawer))
            VStack(spacing: 0) {
                topBar
                if model.messages.isEmpty { emptyState } else { ThreadView(model: model, box: box) }
                ComposerView(model: model, box: box, showAgents: { showAgents = true })
            }
            .modifier(DrawerPage(d: drawer, close: { setDrawer(false) }))
        }
        // The card follows the finger: from the left edge when closed; from anywhere, the drawer
        // included, when open. Simultaneous, and only when clearly sideways, so scrolling still scrolls.
        .simultaneousGesture(DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onChanged { g in
                    let dx = g.translation.width, dy = g.translation.height
                    guard abs(dx) > abs(dy) * 1.5 else { return }                 // a vertical swipe is a scroll
                    if !drawer.blurred { drawer.blurred = true; Keyboard.hide() }  // once per swipe, not per frame
                    if !drawer.open { if g.startLocation.x < 60 { drawer.drag = max(0, dx) } }
                    else { drawer.drag = min(0, dx) }
                }
                .onEnded { g in
                    drawer.blurred = false
                    let predicted = g.predictedEndTranslation.width, w = drawer.width, drag = drawer.drag
                    let open: Bool
                    if !drawer.open { open = g.startLocation.x < 60 && (drag > w * 0.3 || predicted > w * 0.5) }
                    else { open = !(drag < -w * 0.2 || predicted < -w * 0.5) }
                    if open != drawer.open { Haptic.soft(); if open { Task { await model.refreshList() } } }
                    if open == drawer.open && drag == 0 { return }
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) { drawer.open = open; drawer.drag = 0 }
                })
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: PushTarget.open)) { n in
            if let id = n.userInfo?["conv"] as? String { Task { await model.open(id) } }
        }
        .sheet(isPresented: $showBook) { BookSheet(model: model) }
        .sheet(isPresented: $showAgents) { AgentsSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onChange(of: phase) { _, p in if p == .active { Task { await model.resume(); await model.refreshToday() } } }
    }

    private func setDrawer(_ open: Bool) {
        Haptic.soft()
        if open { Keyboard.hide(); Task { await model.refreshList() } }
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) { drawer.open = open; drawer.drag = 0 }
    }

    private func roundButton(_ system: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var topBar: some View {
        HStack {
            roundButton("line.3.horizontal", "Samtaler") { setDrawer(true) }
            Spacer()
            if !model.messages.isEmpty {
                Text(model.roomLabel).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            // On the empty screen the top pill sits between the two sides; the book is in the pill now.
            if model.messages.isEmpty { Color.clear.frame(width: 44, height: 44) }
            else { roundButton("square.and.pencil", "Ny samtale") { Keyboard.hide(); withAnimation { model.newChat() } } }
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

    /// Empty screen, but pull it down and the book and the list are fetched again.
    private var emptyState: some View {
        GeometryReader { geo in
            ScrollView {
                greetingContent.frame(height: geo.size.height)   // the screen's height, so the spacers still place it
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refreshToday(); await model.refreshList() }
        }
    }

    private var greetingContent: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("Logo").resizable().scaledToFit().frame(width: 96).padding(.bottom, 26)
            Text(greeting)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.text).multilineTextAlignment(.center).padding(.horizontal, 28)
            // The book in one line: what the paper is worth and how far from the start, then the day.
            if model.today?.total != nil || LiveBook.shared.snap != nil {
                Button { Haptic.tap(); showBook = true } label: { LiveEquityLine(fallback: model.today?.total) }
                    .buttonStyle(.plain).padding(.top, 14)
            }
            if let h = model.today?.headline {
                Text(h).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).padding(.top, model.today?.total == nil ? 14 : 4).padding(.horizontal, 40)
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
        .onTapGesture { Keyboard.hide() }
        .task { await LiveBook.shared.run() }      // ticks only while the greeting is on screen
    }
}

/// The conversation. Its own view, so a keystroke in the composer or the voice meter does not
/// re-render it; finished bubbles are Equatable, so a new message only builds the new one.
struct ThreadView: View {
    @ObservedObject var model: BookChatModel
    let box: ComposerBox
    @State private var awayFromBottom = false              // scrolled up in a long thread

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        let qs = Self.questions(model.messages)
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                            BookBubble(m: m, question: qs[i], busy: model.sending,
                                       ask: { q in Keyboard.hide(); model.send(q) },
                                       edit: { t in box.edit(t) })
                                .equatable()
                                .id(m.id)
                        }
                        if model.sending {
                            LiveAnswer(label: model.selected.isEmpty ? "Koda tænker" : "\(model.roomLabel) tænker",
                                       live: model.live).padding(.horizontal, 20)
                        }
                        // Room under the last question, so it can sit at the top while the answer arrives.
                        Color.clear.frame(height: model.sending ? geo.size.height * 0.75 : 1).id("bottom")
                    }.padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { Keyboard.hide() }
                // Far up in a long thread: one small arrow back to the end, nothing else.
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentSize.height - (g.contentOffset.y + g.containerSize.height) > 400
                } action: { _, away in awayFromBottom = away }
                .overlay(alignment: .bottom) {
                    if awayFromBottom && !model.sending {
                        Button {
                            Haptic.tap()
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                .frame(width: 36, height: 36).background(Theme.surface2, in: Circle())
                                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        }
                        .accessibilityLabel("Til bunden")
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: awayFromBottom)
                .onChange(of: model.messages.count) { old, new in
                    // Only for what you just asked and its answer; opening a conversation goes to the end.
                    guard model.sending, new > old, let last = model.messages.last else { return }
                    if last.role == "user" {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .top) }   // your question to the top
                    } else if let q = model.messages.last(where: { $0.role == "user" }) {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(q.id, anchor: .top) }      // the answer reads down from it
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.conversationId) { _, _ in
                    // A new conversation gets its id mid-answer; scrolling then would hide the question.
                    guard !model.sending else { return }
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    /// For each answer, the question it was given to: the nearest of yours above it. One pass;
    /// it used to be a firstIndex(of:) with a deep compare of every message, per bubble, per render.
    static func questions(_ ms: [ServerMsg]) -> [String?] {
        var out: [String?] = [], last: String? = nil
        out.reserveCapacity(ms.count)
        for m in ms {
            if m.role == "user" { out.append(nil); if let t = m.text, !t.isEmpty { last = t } } else { out.append(last) }
        }
        return out
    }
}

/// The composer owns the photo and the dictation, and watches the draft, so a keystroke or the
/// voice meter re-renders this card and nothing above it. It used to be part of the screen's own
/// body: every letter typed rebuilt the whole thread.
struct ComposerView: View {
    @ObservedObject var model: BookChatModel
    @ObservedObject var box: ComposerBox
    let showAgents: () -> Void
    @StateObject private var dictation = Dictation()
    @State private var pick: PhotosPickerItem? = nil
    @State private var photo: UIImage? = nil
    @State private var pressStart: Date? = nil
    @State private var holdSend = false
    @FocusState private var focused: Bool

    private var canSend: Bool { (!box.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil) && !model.sending }

    /// Hurtig → Analyse → Udfør → Hurtig: one tap moves on, the pill says where you are. Hold it for
    /// the three spelled out. Not a menu to learn.
    private var modePill: some View {
        let m = BookChatModel.modeInfo(model.mode)
        return Button {
            Haptic.pick()
            withAnimation(.snappy(duration: 0.22)) { model.cycleMode() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: m.icon).font(.system(size: 12, weight: .semibold))
                Text(m.label).font(.system(size: 14, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(model.mode == "fast" ? Theme.text : Theme.accent)
            .padding(.horizontal, 11).frame(height: 38)
            .background(Theme.surface2, in: Capsule())
            .overlay(Capsule().stroke(model.mode == "fast" ? Color.clear : Theme.accent.opacity(0.45), lineWidth: 1))
            .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(BookChatModel.modes, id: \.id) { x in
                Button { Haptic.pick(); model.setMode(x.id) } label: { Label("\(x.label) – \(x.hint)", systemImage: x.id == model.mode ? "checkmark" : x.icon) }
            }
        }
        .accessibilityLabel("Svar: \(m.label)")
        .accessibilityHint("Tryk for at skifte mellem Hurtig, Analyse og Udfør")
    }

    /// Network trouble, said once and quietly above the composer, with a way to try again.
    private func quietLine(_ q: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.offline && model.error == nil ? "wifi.slash" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
            Text(q).font(.system(size: 13)).lineLimit(1)
            if !model.sending {
                Button { Haptic.tap(); model.retryNow() } label: {
                    Text("Prøv igen").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity).padding(.top, 6)
        .transition(.opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let q = model.quiet { quietLine(q) }
            VStack(alignment: .leading, spacing: 8) {
                if let photo {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo).resizable().scaledToFill().frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button { self.photo = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.bg)
                                .frame(width: 20, height: 20).background(Theme.text, in: Circle())
                        }.offset(x: 6, y: -6).accessibilityLabel("Fjern billedet")
                    }.padding(.leading, 6).padding(.top, 4)
                }
                TextField("", text: $box.draft, prompt: Text(model.messages.isEmpty ? (model.selected.isEmpty ? "Spørg Koda" : "Skriv til \(model.roomLabel)") : "Skriv videre").foregroundStyle(Theme.secondary), axis: .vertical)
                    .lineLimit(1...6).focused($focused)
                    .font(.system(size: 17)).foregroundStyle(Theme.text).tint(Theme.accent)
                    .padding(.horizontal, 8).padding(.top, 6)
                if dictation.listening { recordingRow } else {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.text)
                            .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
                    }
                    .accessibilityLabel("Vedhæft billede")
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
                    Button { showAgents() } label: {
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
                    modePill
                    Spacer(minLength: 0)
                    micButton
                    Button {
                        let t = box.draft, p = photo; box.draft = ""; photo = nil
                        model.send(t, image: p)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canSend ? Theme.bg : Theme.secondary)
                            .frame(width: 38, height: 38)
                            .background(canSend ? Theme.text : Theme.surface2, in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
        .background(Theme.bg)
        .animation(.easeOut(duration: 0.2), value: model.quiet)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
                pick = nil
            }
        }
        .onChange(of: dictation.text) { _, t in if dictation.listening { box.draft = t } }
        .onChange(of: box.focusRequest) { _, _ in focused = true }
        .alert("Mikrofon og tale", isPresented: $dictation.denied) {
            Button("OK", role: .cancel) {}
        } message: { Text("Giv Tradster adgang til mikrofon og talegenkendelse under Indstillinger → Tradster.") }
    }
    /// While listening the bottom row becomes: cancel, the voice as a line that only moves
    /// when you speak, stop (keep the words to read over), send.
    var recordingRow: some View {
        HStack(spacing: 10) {
            Button { _ = dictation.stop(); box.draft = "" } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
            }
            .accessibilityLabel("Annullér")
            WideWaveform(meter: dictation.meter).frame(height: 38).accessibilityHidden(true)
            Button { box.draft = dictation.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38).background(Theme.surface2, in: Circle())
            }
            .accessibilityLabel("Stop og ret teksten")
            Button {
                let t = dictation.stop(); box.draft = ""
                if !t.isEmpty { let p = photo; photo = nil; model.send(t, image: p) }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38).background(Theme.accent, in: Circle())
            }
            .accessibilityLabel("Send")
        }
    }

    /// Hold to talk: press, speak, release and it sends. A short tap starts dictation into the
    /// field instead, so you can read it over; tap again to stop.
    var micButton: some View {
        ZStack {
            if dictation.listening { Waveform(meter: dictation.meter) } else {
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
                    let t = dictation.stop(); box.draft = ""
                    if !t.isEmpty { let p = photo; photo = nil; model.send(t, image: p) }
                } else if holdSend == false, dictation.listening, box.draft.isEmpty == false, Date().timeIntervalSince(dictation.startedAt) > 0.6 {
                    box.draft = dictation.stop()                 // second tap: stop, keep the text to edit
                } else {
                    holdSend = false                         // first tap: keep listening
                }
            }
        })
        .accessibilityLabel("Tal")
        .accessibilityHint("Hold inde og tal, slip for at sende")
    }
}

/// What the composer and the screen share: the draft, and a way to ask for the keyboard.
@MainActor final class ComposerBox: ObservableObject {
    @Published var draft = ""
    @Published var focusRequest = 0
    /// "Ret og send igen": the text back in the field, keyboard up.
    func edit(_ t: String) { draft = t; focusRequest += 1 }
}

enum Keyboard {
    @MainActor static func hide() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

// ---- the drawer ------------------------------------------------------------------------
// The drag used to be @State on the screen itself, so every frame of a swipe re-rendered the
// whole screen: thread, cards, charts and composer, 60-120 times a second. Now the offset lives
// here, and only two ViewModifiers watch it. A modifier's `content` is not re-evaluated when the
// modifier's own state changes, so a swipe moves an already-drawn page instead of redrawing it.
@MainActor final class DrawerState: ObservableObject {
    @Published var open = false
    @Published var drag: CGFloat = 0                      // live, while the finger is down
    let width: CGFloat = UIScreen.main.bounds.width - 72
    var blurred = false                                   // the keyboard was put away for this swipe
    var offset: CGFloat { min(width, max(0, (open ? width : 0) + drag)) }
    var amount: CGFloat { width > 0 ? offset / width : 0 }
}

/// The page is a card lying on the drawer that slides aside.
struct DrawerPage: ViewModifier {
    @ObservedObject var d: DrawerState
    let close: () -> Void
    func body(content: Content) -> some View {
        let a = d.amount, off = d.offset
        content
            // The card's shape lives in its background, which runs to the screen's edges; the
            // content stays inside the safe area, so nothing jumps when the drawer starts to open.
            .background {
                // No shadow at all while closed: an offscreen shadow pass under a full-screen card for nothing.
                RoundedRectangle(cornerRadius: 44 * a, style: .continuous).fill(Theme.bg)
                    .shadow(color: .black.opacity(0.5 * a), radius: off > 0 ? 24 : 0, x: off > 0 ? -8 : 0, y: 0)
                    .ignoresSafeArea()
            }
            .overlay {
                if off > 0 {
                    RoundedRectangle(cornerRadius: 44 * a, style: .continuous).fill(Color.black.opacity(0.25 * a))
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .accessibilityLabel("Luk menuen")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .offset(x: off)
    }
}

/// The drawer underneath brightens as the page slides off it.
struct DrawerFloor: ViewModifier {
    @ObservedObject var d: DrawerState
    func body(content: Content) -> some View { content.opacity(Double(0.35 + 0.65 * d.amount)) }
}

/// While Koda works: what it is looking at, line by line with the source's logo, then the text
/// as it is written. Before anything has come back, the breathing mark.
struct LiveAnswer: View {
    let label: String
    @ObservedObject var live: LiveFeed
    private var lines: [StatusLine] { live.lines }
    private var text: String { live.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                HStack(spacing: 8) {
                    if let lg = l.source?.logo, let u = URL(string: lg) {
                        CachedImage(urls: [u], px: 48) { Circle().fill(Theme.surface2) }
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
            if live.thinkStarted != nil || !live.thinking.isEmpty {
                ThoughtRow(text: live.thinking, seconds: live.thinkEnded == nil ? nil : live.thinkSeconds, thinking: live.thinkEnded == nil)
            }
            if text.isEmpty { if live.thinkStarted == nil { Thinking(label: lines.isEmpty ? label : "") } }
            else { AnswerText(text: text, keep: false) }
        }
        .animation(.easeOut(duration: 0.2), value: lines.count)
    }
}

/// The answer as it streams in. Deltas are gathered and handed to the screen at most every 50 ms:
/// the server sends a token at a time, and a re-layout of the growing answer per token was most
/// of the stutter while Koda wrote. 20 updates a second still reads as live typing.
@MainActor final class LiveFeed: ObservableObject {
    @Published private(set) var lines: [StatusLine] = []
    @Published private(set) var text = ""
    @Published private(set) var thinking = ""
    @Published private(set) var thinkEnded: Date? = nil
    private(set) var thinkStarted: Date? = nil
    private var pendingText = "", pendingThink = ""
    private var flusher: Task<Void, Never>? = nil

    var hasText: Bool { !text.isEmpty || !pendingText.isEmpty }
    /// How long Koda thought, once it has started writing (or so far, while it still thinks).
    var thinkSeconds: Double? { thinkStarted.map { (thinkEnded ?? Date()).timeIntervalSince($0) } }

    func status(_ l: StatusLine) { flush(); lines.append(l) }
    func delta(_ s: String) {
        if thinkStarted != nil, thinkEnded == nil { flush(); thinkEnded = Date() }
        pendingText += s; schedule()
    }
    /// The server may send the reasoning as pieces or as the whole text so far; either works.
    func think(_ s: String) {
        if thinkStarted == nil { thinkStarted = Date() }
        let sofar = thinking + pendingThink
        if !sofar.isEmpty, s.hasPrefix(sofar) { pendingThink += String(s.dropFirst(sofar.count)) } else { pendingThink += s }
        schedule()
    }
    func flush() {
        flusher?.cancel(); flusher = nil
        if !pendingThink.isEmpty { thinking += pendingThink; pendingThink = "" }
        if !pendingText.isEmpty { text += pendingText; pendingText = "" }
    }
    private func schedule() {
        guard flusher == nil else { return }
        flusher = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.flusher = nil
            self.flush()
        }
    }
    func reset() {
        flusher?.cancel(); flusher = nil
        pendingText = ""; pendingThink = ""; thinkStarted = nil
        if !lines.isEmpty { lines = [] }
        if !text.isEmpty { text = "" }
        if !thinking.isEmpty { thinking = "" }
        if thinkEnded != nil { thinkEnded = nil }
    }
}

// ---- how Koda got there: reasoning, steps, tables and charts --------------------------------

/// Like the Claude app: one quiet line. While Koda thinks it says "Tænker…" with a light passing
/// over it; afterwards "Tænkte i 12 s". Tap it to read the reasoning in small grey text.
struct ThoughtRow: View {
    let text: String
    let seconds: Double?
    let thinking: Bool
    @State private var open = false
    private var label: String {
        if thinking { return "Tænker…" }
        if let s = seconds { return "Tænkte i \(max(1, Int(s.rounded()))) s" }
        return "Tænkte"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !text.isEmpty else { return }
                Haptic.pick()
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
                    if thinking { Text(label).modifier(Shimmer()) } else { Text(label) }
                    if !text.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint(open ? "Skjul tankegangen" : "Vis tankegangen")
            if open && !text.isEmpty {
                Text(text)
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(Theme.line).frame(width: 2) }
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
    }
}

/// A light that passes over the text while it is live. Only on a view that exists while Koda is
/// thinking, so the repeating animation stops with it.
struct Shimmer: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Theme.text.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(24, g.size.width * 0.5))
                        .offset(x: on ? g.size.width : -max(24, g.size.width * 0.5))
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// What Udfør did, as a short checklist under the answer.
struct StepList: View {
    let steps: [Step]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: s.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(s.failed ? Theme.down : Theme.up)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title ?? "Trin").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        if let d = s.detail, !d.isEmpty { Text(d).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit() }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// A table, a chart or a text from Analyse. Unknown kinds are left out.
struct ArtifactView: View {
    let a: Artifact
    var body: some View {
        switch a.kind {
        case "table": if !(a.rows ?? []).isEmpty || !(a.columns ?? []).isEmpty { ArtifactTable(a: a) }
        case "chart": if (a.series?.count ?? 0) > 1 { ArtifactChart(a: a) }
        case "text": if let t = a.text, !t.isEmpty { box { AnswerText(text: t, size: 15).equatable() } }
        default: EmptyView()
        }
    }
    private func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = a.title, !t.isEmpty { ArtifactTitle(t) }
            c()
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct ArtifactTitle: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.secondary) }
}

/// Scrolls sideways when it is wide; numbers right-aligned in tabular digits. Long tables show
/// the first 30 rows and a line to show the rest.
struct ArtifactTable: View {
    let a: Artifact
    private let cols: [String]
    private let rows: [[String]]
    private let numeric: [Bool]
    @State private var all = false
    init(a: Artifact) {
        self.a = a
        let r = a.rows ?? []
        let n = max(a.columns?.count ?? 0, r.map(\.count).max() ?? 0)
        cols = (a.columns ?? []) + Array(repeating: "", count: max(0, n - (a.columns?.count ?? 0)))
        rows = r.map { $0 + Array(repeating: "", count: max(0, n - $0.count)) }
        numeric = (0..<n).map { i in
            let vals = r.compactMap { i < $0.count ? $0[i] : nil }.filter { !$0.isEmpty }
            guard !vals.isEmpty else { return false }
            let nums = vals.filter { ArtifactTable.isNumber($0) }.count
            return nums * 3 >= vals.count * 2
        }
    }
    static func isNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "kr", with: "")
            .replacingOccurrences(of: "bp", with: "").replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        return Double(t) != nil
    }
    var body: some View {
        let shown = all ? rows : Array(rows.prefix(30))
        VStack(alignment: .leading, spacing: 8) {
            if let t = a.title, !t.isEmpty { ArtifactTitle(t).padding(.horizontal, 12) }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    if cols.contains(where: { !$0.isEmpty }) {
                        GridRow {
                            ForEach(cols.indices, id: \.self) { i in
                                Text(cols[i]).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    .gridColumnAlignment(numeric[i] ? .trailing : .leading)
                            }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(shown.indices, id: \.self) { r in
                        GridRow {
                            ForEach(shown[r].indices, id: \.self) { i in
                                Text(shown[r][i]).font(.system(size: 13, weight: i == 0 ? .medium : .regular)).monospacedDigit()
                                    .foregroundStyle(Theme.text).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            if rows.count > 30 {
                Button { Haptic.pick(); withAnimation(.easeOut(duration: 0.2)) { all.toggle() } } label: {
                    Text(all ? "Vis færre" : "Vis alle \(rows.count) rækker").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// A line with a soft fill, thinned and prepared once like the coin charts. Time on the x-axis when
/// every point has one, otherwise just the order of the points.
struct ArtifactChart: View {
    let a: Artifact
    private let timed: Bool
    private let chart: ChartSeries
    private let tint: Color
    init(a: Artifact) {
        self.a = a
        let s = a.series ?? []
        let isTimed = s.allSatisfy { $0.t != nil }
        timed = isTimed
        let pts = s.enumerated().map { BookPt(t: isTimed ? ($0.element.t ?? 0) : Double($0.offset), c: $0.element.v) }
        chart = ChartSeries(pts, limit: 160, pad: 0.08)
        tint = (s.last?.v ?? 0) >= (s.first?.v ?? 0) ? Theme.up : Theme.down
    }
    var body: some View {
        let fade = LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
        let lo = chart.lo, hi = chart.hi, pad = chart.pad
        VStack(alignment: .leading, spacing: 8) {
            if let t = a.title, !t.isEmpty { ArtifactTitle(t) }
            Group {
                if timed {
                    Chart(chart.points) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("lo", lo - pad), yEnd: .value("v", p.c)).foregroundStyle(fade)
                        LineMark(x: .value("t", p.t), y: .value("v", p.c)).foregroundStyle(tint).lineStyle(.init(lineWidth: 2, lineCap: .round))
                    }
                } else {
                    Chart(chart.points) { p in
                        AreaMark(x: .value("i", p.id), yStart: .value("lo", lo - pad), yEnd: .value("v", p.c)).foregroundStyle(fade)
                        LineMark(x: .value("i", p.id), y: .value("v", p.c)).foregroundStyle(tint).lineStyle(.init(lineWidth: 2, lineCap: .round))
                    }
                    .chartXAxis(.hidden)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().font(.system(size: 9)).foregroundStyle(Theme.secondary) } }
            .frame(height: 150)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// Settings: one switch and what Koda remembers about you.
struct SettingsSheet: View {
    @AppStorage("stream") private var stream = true
    @State private var facts: [String] = []
    @State private var provider = ""
    @State private var model = ""
    @State private var keyDraft = ""
    @State private var keyBusy = false
    @State private var keyNote: String? = nil
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
                // The Claude API key, pasted here from the phone. It goes straight to the server, which
                // checks it with Anthropic and stores it; the app never keeps it.
                Section {
                    HStack {
                        Text("Model").foregroundStyle(Theme.text)
                        Spacer()
                        Text(provider == "claude" ? "Claude · \(model)" : provider == "openrouter" ? "OpenRouter · \(model)" : "ingen").foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    SecureField("", text: $keyDraft, prompt: Text("Indsæt Claude API-nøgle (sk-ant-…)").foregroundStyle(Theme.secondary))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().foregroundStyle(Theme.text)
                    Button {
                        Task { await saveKey() }
                    } label: {
                        HStack { if keyBusy { ProgressView().tint(Theme.accent) }; Text(provider == "claude" ? "Skift nøgle" : "Brug Claude") }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || keyBusy)
                    .foregroundStyle(Theme.accent)
                    if let keyNote { Text(keyNote).font(.system(size: 12)).foregroundStyle(keyNote.hasPrefix("Gemt") ? Theme.up : Theme.down) }
                } header: { Text("Kodas model") } footer: {
                    Text("Lav nøglen på platform.claude.com → API keys. Den gemmes kun på serveren.").foregroundStyle(Theme.secondary)
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
            .task { await load(); await loadLLM() }
        }
        .preferredColorScheme(.dark)
    }
    private func loadLLM() async {
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/settings/llm")!); r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: r), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        provider = j["provider"] as? String ?? ""; model = j["model"] as? String ?? ""
    }
    private func saveKey() async {
        keyBusy = true; keyNote = nil
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/settings/anthropic-key")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["key": keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)])
        if let (d, resp) = try? await URLSession.shared.data(for: r) {
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            if (resp as? HTTPURLResponse)?.statusCode == 200 { keyNote = "Gemt. Koda bruger nu Claude."; keyDraft = ""; Haptic.done(); await loadLLM() }
            else { keyNote = j?["error"] as? String ?? "Kunne ikke gemme."; Haptic.fail() }
        } else { keyNote = "Ingen forbindelse."; Haptic.fail() }
        keyBusy = false
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
            if !label.isEmpty {
                Text(label).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    .opacity(on ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            }
        }
        .onAppear { on = true }
    }
}

struct WideWaveform: View {
    @ObservedObject var meter: Dictation.Meter
    private var history: [CGFloat] { meter.history }
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
    @ObservedObject var meter: Dictation.Meter
    private var level: CGFloat { meter.level }
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
            let d = Tradster.date(c.updated) ?? .distantPast
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
                        .accessibilityLabel("Luk søgning")
                    } else {
                        Text("Tradster").font(.system(size: 30, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                        Spacer()
                        Button { searching = true; searchFocused = true } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                                .frame(width: 44, height: 44).background(Theme.surface, in: Circle())
                        }
                        .accessibilityLabel("Søg i samtaler")
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
                                Button { Haptic.pick(); onClose(); Task { await model.open(c.id) } } label: {
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
                                .contextMenu { Button(role: .destructive) { Haptic.rigid(); Task { await model.delete(c.id) } } label: { Label("Slet", systemImage: "trash") } }
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
                .accessibilityLabel("Indstillinger")
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
    var asTab = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LabSection().padding(.bottom, 6)
                    LiveBasket(logos: Dictionary(model.openCards.compactMap { c in c.symbol.map { ($0, c) } }, uniquingKeysWith: { a, _ in a }))
                        .padding(.bottom, 8)
                    if let h = model.today?.headline { Text(h).font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.bottom, 4) }
                    if !model.openCards.isEmpty { CardStrip(cards: model.openCards).padding(.horizontal, -20) }
                    if model.openCards.isEmpty { Text("Bogen er flad.").foregroundStyle(Theme.secondary) }
                }.padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(asTab ? "" : "Bogen lige nu").navigationBarTitleDisplayMode(.inline)
            .toolbar(asTab ? .hidden : .visible, for: .navigationBar)
            .safeAreaInset(edge: .top) { if asTab { Color.clear.frame(height: 50) } }   // room for the top pill
            .toolbar { if !asTab { ToolbarItem(placement: .topBarTrailing) { Button("Luk") { dismiss() }.foregroundStyle(Theme.secondary) } } }
            .refreshable { await model.bootstrap(); await LiveBook.shared.refresh(); await ProposalModel.shared.load() }
            .task { await LiveBook.shared.run() }
        }
        .preferredColorScheme(.dark)
    }
}

// ---- messages ---------------------------------------------------------------------------
/// Equatable on what it shows, so a re-render of the thread (a keystroke, a token, the drawer)
/// skips every finished bubble instead of rebuilding its markdown, cards and charts.
struct BookBubble: View, Equatable {
    static func == (a: BookBubble, b: BookBubble) -> Bool { a.m == b.m && a.question == b.question && a.busy == b.busy }
    let m: ServerMsg
    var question: String? = nil              // what this answer answered, for "Spørg igen"
    var busy = false
    var ask: (String) -> Void = { _ in }
    var edit: (String) -> Void = { _ in }
    private var mine: Bool { m.role == "user" }
    /// The words without the markdown, for the clipboard and the share sheet.
    private var plain: String { String(AnswerText.inline(m.text ?? "").characters) }
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
                        CachedImage(urls: [u], px: 540, fill: true) { Theme.surface2 }
                        .frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if let t = m.text, !t.isEmpty {
                        Text(t).font(.system(size: 16)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contextMenu {
                                Button { UIPasteboard.general.string = t; Haptic.done() } label: { Label("Kopiér", systemImage: "doc.on.doc") }
                                Button { edit(t) } label: { Label("Ret og send igen", systemImage: "pencil") }
                                ShareLink(item: t) { Label("Del", systemImage: "square.and.arrow.up") }
                            }
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
                if let th = m.thinking, !th.isEmpty { ThoughtRow(text: th, seconds: m.thinking_s, thinking: false) }
                if let t = m.text, !t.isEmpty {
                    // Long-press: copy, share, or ask the same question again.
                    AnswerText(text: t).equatable()
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contextMenu {
                            Button { UIPasteboard.general.string = plain; Haptic.done() } label: { Label("Kopiér", systemImage: "doc.on.doc") }
                            ShareLink(item: plain) { Label("Del", systemImage: "square.and.arrow.up") }
                            if let q = question {
                                Button { ask(q) } label: { Label("Spørg igen", systemImage: "arrow.clockwise") }.disabled(busy)
                            }
                        } preview: {
                            AnswerText(text: String(t.prefix(700)) + (t.count > 700 ? " …" : ""))
                                .padding(18).frame(width: 340).background(Theme.bg)
                        }
                }
                if let st = m.steps, !st.isEmpty { StepList(steps: st) }
                if let arts = m.artifacts {
                    ForEach(Array(arts.enumerated()), id: \.offset) { _, a in ArtifactView(a: a) }
                }
                if let cs = m.cards, !cs.isEmpty { CardStrip(cards: cs).padding(.top, 2).padding(.horizontal, -20) }
                if let src = m.sources, !src.isEmpty { Sources(items: src) }
            }.padding(.horizontal, 20)
        }
    }
}

/// Answers in light markdown: **bold**, *italic*, `code` and links inline; bullet and numbered
/// lines as a hanging list; short headings in the serif. Digits are tabular, so numbers line up.
struct AnswerText: View, Equatable {
    let text: String
    var size: CGFloat = 16.5
    /// Finished answers keep their parsed blocks; the live answer does not (it changes 20 times a second).
    var keep = true
    static func == (a: AnswerText, b: AnswerText) -> Bool { a.text == b.text && a.size == b.size }

    fileprivate enum Block { case para(AttributedString), bullet(AttributedString), numbered(String, AttributedString), heading(AttributedString) }
    private final class Parsed { let blocks: [Block]; init(_ b: [Block]) { blocks = b } }
    private final class Inline { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    // Markdown is parsed once per text, not once per render: every token of a streamed answer used to
    // re-parse every visible bubble above it. The inline cache also covers the live answer, whose
    // finished paragraphs are then not parsed again as the last one grows.
    private static let parsed: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 300; return c }()
    private static let inlines: NSCache<NSString, Inline> = { let c = NSCache<NSString, Inline>(); c.countLimit = 3000; return c }()
    private static let bulletRx = try! NSRegularExpression(pattern: #"^[-*•]\s+"#)
    private static let numberRx = try! NSRegularExpression(pattern: #"^\d{1,2}[.)]\s+"#)
    private static let headingRx = try! NSRegularExpression(pattern: #"^#{1,4}\s+"#)

    private static func prefix(_ rx: NSRegularExpression, _ line: String) -> String.Index? {
        let ns = line as NSString
        guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Range(m.range, in: line)?.upperBound
    }
    private static func blocks(_ text: String, keep: Bool) -> [Block] {
        if keep, let p = parsed.object(forKey: text as NSString) { return p.blocks }
        var out: [Block] = [], para: [String] = []
        func flush() { if !para.isEmpty { out.append(.para(inline(para.joined(separator: "\n")))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let r = prefix(bulletRx, line) {
                flush(); out.append(.bullet(inline(String(line[r...]))))
            } else if let r = prefix(numberRx, line) {
                flush(); out.append(.numbered(line[..<r].trimmingCharacters(in: .whitespaces), inline(String(line[r...]))))
            } else if let r = prefix(headingRx, line) {
                flush(); out.append(.heading(inline(String(line[r...]))))
            } else { para.append(line) }
        }
        flush()
        if keep { parsed.setObject(Parsed(out), forKey: text as NSString) }
        return out
    }
    static func inline(_ s: String) -> AttributedString {
        if let v = inlines.object(forKey: s as NSString) { return v.value }
        let v = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        inlines.setObject(Inline(v), forKey: s as NSString)
        return v
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text, keep: keep).enumerated()), id: \.offset) { _, b in
                switch b {
                case .para(let t):
                    Text(t)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(Theme.secondary)
                        Text(t)
                    }.padding(.leading, 2)
                case .numbered(let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(n).foregroundStyle(Theme.secondary).frame(minWidth: 20, alignment: .trailing)
                        Text(t)
                    }
                case .heading(let t):
                    Text(t).font(.system(size: size + 2, weight: .semibold, design: .serif)).padding(.top, 4)
                }
            }
        }
        .font(.system(size: size)).monospacedDigit()
        .foregroundStyle(Theme.text).lineSpacing(4).tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let m = maxAbs          // once, not once per square
        let longs = cards.filter { $0.side == "long" }.sorted { ($0.bp ?? 0) > ($1.bp ?? 0) }
        let shorts = cards.filter { $0.side == "short" }.sorted { ($0.bp ?? 0) > ($1.bp ?? 0) }
        let other = cards.filter { $0.side != "long" && $0.side != "short" }
        VStack(alignment: .leading, spacing: 14) {
            if !longs.isEmpty { section("LANGE", longs, m) }
            if !shorts.isEmpty { section("KORTE", shorts, m) }
            if !other.isEmpty { section("ANDET", other, m) }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
    private func section(_ title: String, _ list: [BookCard], _ maxAbs: Double) -> some View {
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
                            CachedImage(urls: [u], px: 42) { icon(src.kind) }
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
    private let chart: ChartSeries?
    init(c: BookCard) {
        self.c = c
        if let s = c.series, s.count > 2 {
            let ref = c.isMarket ? (c.prev_close ?? s[0].c) : (c.entry ?? s[0].c)
            chart = ChartSeries(s, extra: [ref] + (c.stop.map { [$0] } ?? []), limit: 240, pad: 0.08)
        } else { chart = nil }
    }
    @Environment(\.dismiss) private var dismiss
    private var bpVal: Double { c.isMarket ? (c.change_pct ?? 0) * 100 : Double(c.bp ?? 0) }
    private var tint: Color { bpVal >= 0 ? Theme.up : Theme.down }
    private func px(_ v: Double) -> String { v >= 100 ? String(format: "%.2f", v) : v >= 1 ? String(format: "%.4f", v) : String(format: "%.6g", v) }
    private func date(_ s: String?) -> Date? { Tradster.date(s) }
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

                    if let ch = chart, let s = c.series {
                        let ref = c.isMarket ? (c.prev_close ?? s[0].c) : (c.entry ?? s[0].c)
                        let lo = ch.lo, hi = ch.hi, pad = ch.pad
                        let fade = LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                        Chart {
                            ForEach(ch.points) { p in
                                AreaMark(x: .value("t", p.t), yStart: .value("lo", lo - pad), yEnd: .value("v", p.c))
                                    .foregroundStyle(fade)
                                LineMark(x: .value("t", p.t), y: .value("v", p.c)).foregroundStyle(tint).lineStyle(.init(lineWidth: 2.4, lineCap: .round))
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.secondary).frame(width: 30, height: 30).background(Theme.surface2, in: Circle()) }.accessibilityLabel("Luk") } }
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
    private let spark: [Double]
    init(c: BookCard) { self.c = c; spark = (c.series?.count ?? 0) > 2 ? ChartSeries.thin(c.series ?? [], limit: 48).map(\.c) : [] }
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
            if !spark.isEmpty {
                // A tile's line has no axes and no interaction: a drawn path is the same picture for a
                // fraction of what a Swift Charts view costs in a row you swipe through.
                Sparkline(values: spark).stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
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

/// A price series made ready for a chart once, outside `body`: thinned to at most `limit` points
/// (each bucket keeps its high and its low, so a spike survives), dates built, domain worked out.
/// A card used to rebuild hundreds of Dates and two marks per hourly point on every render.
struct ChartSeries {
    struct P: Identifiable { let id: Int; let t: Date; let c: Double }
    let points: [P]
    let lo: Double, hi: Double, pad: Double
    init(_ s: [BookPt], extra: [Double] = [], limit: Int = 120, pad frac: Double = 0.1) {
        let thin = Self.thin(s, limit: limit)
        points = thin.enumerated().map { P(id: $0.offset, t: Date(timeIntervalSince1970: $0.element.t), c: $0.element.c) }
        var l = Double.infinity, h = -Double.infinity
        for v in s { l = min(l, v.c); h = max(h, v.c) }
        for v in extra { l = min(l, v); h = max(h, v) }
        if !l.isFinite { l = 0; h = 1 }
        lo = l; hi = h; pad = max((h - l) * frac, 1e-9)
    }
    static func thin(_ s: [BookPt], limit: Int) -> [BookPt] {
        guard s.count > limit, limit >= 4 else { return s }
        let buckets = limit / 2
        let size = Double(s.count - 2) / Double(buckets)
        var out: [BookPt] = [s[0]]
        out.reserveCapacity(limit + 2)
        for b in 0..<buckets {
            let a = 1 + Int(Double(b) * size), z = min(s.count - 1, 1 + Int(Double(b + 1) * size))
            guard a < z else { continue }
            var lo = a, hi = a
            for i in a..<z { if s[i].c < s[lo].c { lo = i }; if s[i].c > s[hi].c { hi = i } }
            if lo == hi { out.append(s[lo]) } else { out.append(s[min(lo, hi)]); out.append(s[max(lo, hi)]) }
        }
        out.append(s[s.count - 1])
        return out
    }
}

/// The tile's little line: values scaled into the frame, no axes.
struct Sparkline: Shape {
    let values: [Double]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return p }
        let span = hi > lo ? hi - lo : 1
        let dx = r.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: r.minX + CGFloat(i) * dx, y: r.maxY - CGFloat((v - lo) / span) * r.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

struct CoinLogo: View {
    let url: String?; let fallback: String?; var size: CGFloat = 36
    var body: some View {
        CachedImage(url: url, fallback: fallback, px: Int(size * 3)) { placeholder }
        .frame(width: size, height: size).clipShape(Circle())
    }
    private var placeholder: some View {
        Circle().fill(Theme.surface2).overlay(Image(systemName: "bitcoinsign").font(.system(size: size * 0.4)).foregroundStyle(Theme.secondary))
    }
}

struct CoinCard: View {
    let c: BookCard
    private let chart: ChartSeries?
    private let openedAt: Date?
    init(c: BookCard) {
        self.c = c
        openedAt = Tradster.date(c.opened_at)
        if let s = c.series, s.count > 2 {
            if c.isMarket { chart = ChartSeries(s, extra: [c.prev_close ?? s[0].c], limit: 120, pad: 0.1) }
            else if let e = c.entry { chart = ChartSeries(s, extra: [e], limit: 120, pad: 0.1) }
            else { chart = nil }
        } else { chart = nil }
    }
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
            if let ch = chart {
                let lo = ch.lo, hi = ch.hi, pad = ch.pad
                let fade = LinearGradient(colors: [col.opacity(0.22), col.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                Chart {
                    ForEach(ch.points) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("lo", lo - pad), yEnd: .value("kurs", p.c))
                            .foregroundStyle(fade)
                        LineMark(x: .value("t", p.t), y: .value("kurs", p.c))
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
            if let ch = chart, let e = c.entry {
                let lo = ch.lo, hi = ch.hi, pad = ch.pad
                let fade = LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                Chart {
                    ForEach(ch.points) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("lo", lo - pad), yEnd: .value("kurs", p.c))
                            .foregroundStyle(fade)
                        LineMark(x: .value("t", p.t), y: .value("kurs", p.c))
                            .foregroundStyle(tint).lineStyle(.init(lineWidth: 2, lineCap: .round))
                    }
                    RuleMark(y: .value("ind", e)).foregroundStyle(Theme.secondary.opacity(0.6)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("ind \(px(e))").font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                    if let d = openedAt {
                        RuleMark(x: .value("åbnet", d)).foregroundStyle(Theme.secondary.opacity(0.35)).lineStyle(.init(lineWidth: 1))
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
    /// 10.234 — Danish thousands, no decimals.
    // Formatters are made once. Building a NumberFormatter or DateFormatter costs about as much as
    // laying out a card, and every card asked for two or three of them on every render.
    private static let krFormat: NumberFormatter = {
        let f = NumberFormatter(); f.locale = Locale(identifier: "da_DK"); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
    private static let clock: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "da_DK"); f.dateFormat = "HH:mm"; return f }()
    private static let dayClock: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "da_DK"); f.dateFormat = "d. MMM HH:mm"; return f }()
    static func kr(_ v: Double) -> String {
        krFormat.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded()))
    }
    private static let dayOnly: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func day(_ s: String) -> Date? { s.count == 10 ? dayOnly.date(from: s) : nil }
    /// The server's timestamps, with or without fractional seconds.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return ISO8601DateFormatter.plain.date(from: s) ?? ISO8601DateFormatter.withFraction.date(from: s)
    }
    static func when(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        return (Calendar.current.isDateInToday(d) ? clock : dayClock).string(from: d)
    }
}

extension ISO8601DateFormatter {
    static let plain = ISO8601DateFormatter()
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
