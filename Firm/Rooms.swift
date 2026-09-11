import SwiftUI

struct Poll: Codable, Hashable {
    let question: String?; let options: [String]?; let votes: [String: Vote]?
    struct Vote: Codable, Hashable { let choice: String?; let why: String? }
}
struct RoomMsg: Codable, Identifiable, Hashable {
    var id: String { (at ?? "") + "|" + (who ?? "") + "|" + String((text ?? "").prefix(32)) }
    let role: String?; let who: String?; let text: String?; let at: String?
    let poll: Poll?; let to: [String]?
}
/// A message someone made in the room, waiting to become the verdict on the idea.
struct PendingVerdict: Identifiable {
    let id = UUID()
    let msg: RoomMsg
    let reject: Bool
    var who: String { msg.who ?? "" }
    var role: ButtonRole? { reject ? .destructive : nil }
    var buttonTitle: String {
        let name = who.capitalized
        return reject ? "Reject, using \(name)'s reason" : "Keep, using \(name)'s reason"
    }
}

struct RoomSource: Codable, Hashable { let agent: String?; let slug: String? }
struct Room: Codable, Identifiable, Hashable {
    let id: String; let topic: String?; let participants: [String]?; let kind: String?
    let source: RoomSource?
    let created: String?; let count: Int?; let last: RoomMsg?; let speaking: String?
    let seed: String?; let messages: [RoomMsg]?
}
struct RoomsPayload: Codable { let rooms: [Room]?; let board: [String]? }
/// Rooms are pushed by this, not by `Room`. A Room's value changes on every poll — a new
/// message, a different speaker — and a value-based push whose value no longer exists
/// gets dropped by SwiftUI, which threw you out of the room mid-conversation.
struct RoomRef: Hashable { let id: String }
struct RoomPayload: Codable { let room: Room?; let speaking: String? }

@MainActor final class RoomsModel: ObservableObject {
    @Published var rooms: [Room] = []
    @Published var board: [String] = []
    @Published var error: String? = nil
    func load() async {
        guard let p: RoomsPayload = await fetch("/rooms") else { return }
        let fresh = p.rooms ?? []
        if fresh != rooms { rooms = fresh }
        if (p.board ?? []) != board { board = p.board ?? [] }
    }
    func remove(_ id: String) async {
        rooms.removeAll { $0.id == id }          // go immediately; the server catches up
        var r = URLRequest(url: URL(string: "\(Store.base)/rooms/\(id)")!)
        r.httpMethod = "DELETE"
        r.setValue("FirmApp/4.9", forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }
    func create(topic: String, seed: String, participants: [String], board: Bool,
                source: (agent: String, slug: String)? = nil) async -> Room? {
        var r = URLRequest(url: URL(string: "\(Store.base)/rooms")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.2", forHTTPHeaderField: "User-Agent")
        var payload: [String: Any] = ["topic": topic, "seed": seed, "participants": participants,
                                      "kind": board ? "board" : "group"]
        if let s = source { payload["source"] = ["agent": s.agent, "slug": s.slug] }
        r.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { error = "Could not reach the server"; return nil }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            error = (j?["error"] as? String) ?? "HTTP \(h.statusCode)"; return nil
        }
        await load()
        return (try? JSONDecoder().decode(RoomPayload.self, from: d))?.room
    }
    private func fetch<T: Decodable>(_ path: String) async -> T? {
        var r = URLRequest(url: URL(string: Store.base + path)!)
        r.setValue("FirmApp/4.2", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

@MainActor final class RoomModel: ObservableObject {
    @Published var room: Room? = nil
    @Published var speaking: String? = nil
    @Published var error: String? = nil
    let id: String
    private var poll: Task<Void, Never>? = nil
    init(id: String) { self.id = id }
    func start() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: .seconds(self?.speaking != nil ? 2 : 6))
            }
        }
    }
    func stop() { poll?.cancel() }
    func load() async {
        var r = URLRequest(url: URL(string: "\(Store.base)/rooms/\(id)")!)
        r.setValue("FirmApp/4.2", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(RoomPayload.self, from: d) else { return }
        if p.room != room { room = p.room }
        if p.speaking != speaking { speaking = p.speaking }
    }
    /// Ask the room a closed question with any options you like.
    func ask(_ question: String, _ options: [String]) async {
        var r = URLRequest(url: URL(string: "\(Store.base)/rooms/\(id)/poll")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.3", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["question": question, "options": options])
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { error = "Could not send"; return }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            error = (j?["error"] as? String) ?? "HTTP \(h.statusCode)"; return
        }
        await load()
    }
    func say(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !body.isEmpty else { return }
        var r = URLRequest(url: URL(string: "\(Store.base)/rooms/\(id)/say")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.2", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": body])
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { error = "Could not send"; return }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            error = (j?["error"] as? String) ?? "HTTP \(h.statusCode)"
            UINotificationFeedbackGenerator().notificationOccurred(.error); return
        }
        await load()
    }
}

// ---- start a room --------------------------------------------------------------------
struct NewRoomSheet: View {
    let topic: String; let seed: String
    var source: (agent: String, slug: String)? = nil
    @EnvironmentObject var store: Store
    @StateObject private var model = RoomsModel()
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var boardMeeting = false
    @State private var creating = false
    var onCreated: (Room) -> Void
    private var eligible: [Agent] { store.agents.filter { $0.id != "elliot" && $0.id != "main" } }
    var body: some View {
        NavigationStack {
            List {
                Section { Text(topic).font(.system(size: 15, weight: .medium)) } header: { Text("About") }
                Section {
                    Toggle(isOn: $boardMeeting) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Board meeting")
                            Text(model.board.isEmpty ? "Matt chairs, with pricing and research"
                                                     : model.board.map { $0.capitalized }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !boardMeeting {
                    Section {
                        ForEach(eligible) { a in
                            Button {
                                if picked.contains(a.id) { picked.remove(a.id) } else { picked.insert(a.id) }
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(agent: a, size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.display).foregroundStyle(.primary)
                                        Text(a.tidyRole).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: picked.contains(a.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked.contains(a.id) ? Color.accentColor : Color.secondary.opacity(0.4))
                                }
                            }
                        }
                    } header: { Text("Who should talk about it") }
                    footer: { Text("Pick two or more. Elliot is never in a room — he runs real money and works alone.") }
                }
            }
            .navigationTitle("Discuss").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        creating = true
                        Task {
                            if let r = await model.create(topic: topic, seed: seed,
                                                          participants: Array(picked), board: boardMeeting,
                                                          source: source) {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss(); onCreated(r)
                            }
                            creating = false
                        }
                    }.disabled(creating || (!boardMeeting && picked.count < 2))
                }
            }
            .task { await model.load() }
            .alert("Could not start", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
                Button("OK", role: .cancel) {} } message: { Text(model.error ?? "") }
        }
    }
}

// ---- the room itself -----------------------------------------------------------------
struct RoomView: View {
    let roomId: String
    @EnvironmentObject var store: Store
    @StateObject private var model: RoomModel
    @State private var draft = ""
    @State private var showPoll = false
    @State private var mentionQuery: String? = nil
    @State private var rejecting: RoomMsg? = nil
    @State private var rejectReason = ""
    @State private var pending: PendingVerdict? = nil
    @State private var verdictNote: String? = nil
    init(roomId: String) { self.roomId = roomId; _model = StateObject(wrappedValue: RoomModel(id: roomId)) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let seed = model.room?.seed, !seed.isEmpty {
                            Text(seed).font(.system(size: 14)).foregroundStyle(.secondary)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 12)
                        }
                        ForEach(Array((model.room?.messages ?? []).enumerated()), id: \.offset) { _, m in
                            RoomBubble(m: m, store: store)
                                .contextMenu {
                                    Button { UIPasteboard.general.string = m.text ?? "" } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    if let who = m.who, who != "marco" {
                                        Button { draft = "@\(who) " } label: {
                                            Label("Reply to \(who.capitalized)", systemImage: "arrowshape.turn.up.left")
                                        }
                                        if model.room?.source != nil {
                                            Button(role: .destructive) {
                                                pending = PendingVerdict(msg: m, reject: true)
                                            } label: {
                                                Label("Reject the idea, using this", systemImage: "hand.thumbsdown")
                                            }
                                            Button {
                                                pending = PendingVerdict(msg: m, reject: false)
                                            } label: {
                                                Label("Keep the idea, using this", systemImage: "hand.thumbsup")
                                            }
                                        }
                                        Button { rejecting = m; rejectReason = "" } label: {
                                            Label("Push back on this", systemImage: "arrow.uturn.backward")
                                        }
                                    }
                                }
                        }
                        if let who = model.speaking {
                            HStack(spacing: 8) {
                                if let a = store.agents.first(where: { $0.id == who }) { Avatar(agent: a, size: 26) }
                                TypingDots()
                                Text("\(who.capitalized) is thinking").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }.padding(.horizontal, 12)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.vertical, 12)
                }
                .onChange(of: model.room?.messages?.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: model.speaking) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            if let q = mentionQuery {
                let people = (model.room?.participants ?? []).filter { q.isEmpty || $0.hasPrefix(q.lowercased()) }
                if !people.isEmpty {
                    MentionBar(ids: people, store: store) { complete($0) }
                }
            }
            HStack(spacing: 10) {
                Button { showPoll = true } label: { Image(systemName: "checklist").font(.system(size: 20)) }
                    .disabled(model.speaking != nil)
                TextField("Say something, or @name one of them…", text: $draft, axis: .vertical).lineLimit(1...5)
                    .onChange(of: draft) { _, v in
                        guard let at = v.lastIndex(of: "@") else { mentionQuery = nil; return }
                        let tail = v[v.index(after: at)...]
                        mentionQuery = tail.contains(" ") ? nil : String(tail)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    let t = draft; draft = ""; mentionQuery = nil
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await model.say(t) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }.disabled(!canSend)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.room?.topic ?? "Room").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.room?.topic ?? "Room").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text((model.room?.participants ?? []).map { $0.capitalized }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .onAppear { model.start() }.onDisappear { model.stop() }
        .sheet(isPresented: $showPoll) { PollSheet { q, opts in Task { await model.ask(q, opts) } } }
        .confirmationDialog(pendingTitle, isPresented: pendingShown,
                            titleVisibility: .visible, presenting: pending) { p in
            Button(p.buttonTitle, role: p.role) { Task { await sendVerdict(p) } }
        } message: { p in
            Text(p.msg.text ?? "")
        }
        .alert("Done", isPresented: noteShown) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verdictNote ?? "")
        }
        .sheet(item: $rejecting) { m in
            NavigationStack {
                Form {
                    Section("They said") {
                        Text(m.text ?? "").font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(6)
                    }
                    Section("Why is that wrong?") {
                        TextField("Optional — but a reason makes the next answer better", text: $rejectReason, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
                .navigationTitle("Reject").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rejecting = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            let who = m.who ?? "", why = rejectReason.trimmingCharacters(in: .whitespaces)
                            rejecting = nil
                            let text = "@\(who) I do not accept that." + (why.isEmpty ? "" : " \(why)") +
                                       " Answer again, and address the objection directly."
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            Task { await model.say(text) }
                        }
                    }
                }
            }.presentationDetents([.medium])
        }
        .alert("Could not send", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {} } message: { Text(model.error ?? "") }
    }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.speaking == nil }
    private var pendingShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }
    private var noteShown: Binding<Bool> {
        Binding(get: { verdictNote != nil }, set: { if !$0 { verdictNote = nil } })
    }
    private var pendingTitle: String {
        guard let p = pending else { return "" }
        return p.reject ? "Reject the idea?" : "Keep the idea?"
    }

    /// Settle the idea this room was started from, using an agent's own words as the reason.
    private func sendVerdict(_ p: PendingVerdict) async {
        guard let src = model.room?.source, let agent = src.agent, let slug = src.slug else { return }
        let who = p.who
        let reason = p.msg.text ?? ""
        let reject = p.reject
        pending = nil
        var r = URLRequest(url: URL(string: "\(Store.base)/agents/\(agent)/ideas/\(slug)/verdict")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.6", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "verdict": reject ? "reject" : "keep",
            "reason": "\(who.capitalized) in the room: \(reason)"])
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            model.error = "Could not record that verdict"; return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        verdictNote = reject
            ? "Rejected, with \(who.capitalized)’s reason. It is out of your inbox."
            : "Kept, with \(who.capitalized)’s reason."
        await model.say("Noted — I have \(reject ? "rejected" : "kept") this, using \(who.capitalized)’s reasoning.")
    }
    private func complete(_ id: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@" + id + " "
        mentionQuery = nil
    }
}

struct RoomBubble: View {
    let m: RoomMsg; let store: Store
    private var mine: Bool { m.who == "marco" }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) }
            else if let a = store.agents.first(where: { $0.id == m.who }) { Avatar(agent: a, size: 26) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if let p = m.poll { PollCard(poll: p, store: store) }
                if !mine {
                    Text((m.who ?? "").capitalized).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.agentHue(m.who ?? ""))
                }
                if m.poll == nil {
                Text(m.text ?? "").font(.system(size: 15)).foregroundStyle(mine ? .white : .primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Text(Fmt.when(m.at)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if !mine { Spacer(minLength: 40) }
        }.padding(.horizontal, 12)
    }
}

// ---- rooms list, inside the Chat tab -------------------------------------------------
struct RoomsList: View {
    @EnvironmentObject var store: Store
    @StateObject private var model = RoomsModel()
    var body: some View {
        List {
            ForEach(model.rooms) { r in
                NavigationLink(value: RoomRef(id: r.id)) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: r.kind == "board" ? "person.3.sequence.fill" : "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(r.kind == "board" ? .orange : Color.accentColor)
                            Text(r.topic ?? "Room").font(.system(size: 16, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(Fmt.when(r.last?.at ?? r.created)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text((r.participants ?? []).map { $0.capitalized }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let sp = r.speaking {
                            HStack(spacing: 5) { TypingDots(scale: 0.6); Text("\(sp.capitalized) is thinking").font(.caption).foregroundStyle(.secondary) }
                        } else if let l = r.last {
                            Text("\(l.who == "marco" ? "You" : (l.who ?? "").capitalized): \(l.text ?? "")")
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 3)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        Task { await model.remove(r.id) }
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .task { await model.load() }.refreshable { await model.load() }
        .overlay {
            if model.rooms.isEmpty {
                ContentUnavailableView("No rooms yet", systemImage: "person.3",
                    description: Text("Start one from an idea in your inbox — pick who should argue about it."))
            }
        }
    }
}


struct PollCard: View {
    let poll: Poll; let store: Store
    private var tally: [(String, Int)] {
        let counts = (poll.votes ?? [:]).values.reduce(into: [String: Int]()) { $0[$1.choice ?? "—", default: 0] += 1 }
        return (poll.options ?? []).map { ($0, counts[$0] ?? 0) }
    }
    private var total: Int { max(1, (poll.votes ?? [:]).count) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(poll.question ?? "").font(.system(size: 15, weight: .semibold))
            ForEach(Array(tally.enumerated()), id: \.offset) { _, row in
                let (opt, n) = row
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(opt).font(.system(size: 14)); Spacer()
                        Text("\(n)").font(.system(size: 14, weight: .semibold)).monospacedDigit() }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(4, g.size.width * CGFloat(n) / CGFloat(total)))
                        }
                    }.frame(height: 7)
                }
            }
            if let v = poll.votes, !v.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(v.sorted(by: { $0.key < $1.key }), id: \.key) { who, vote in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(who.capitalized).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.agentHue(who))
                            Text(vote.choice ?? "").font(.system(size: 12, weight: .medium))
                        }
                        Text(vote.why ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct PollOption: Identifiable, Hashable {
    let id = UUID()
    var text: String = ""
}

struct PollSheet: View {
    var onAsk: (String, [String]) -> Void
    /// Blank rows never reach the room, and two identical options would collide once the
    /// results come back.
    private var cleaned: [String] {
        var seen = Set<String>()
        return options.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options: [PollOption] = [PollOption(), PollOption()]
    private let presets: [(String, [String])] = [
        ("Go / No-go", ["Go", "No-go"]),
        ("Yes / No / Needs work", ["Yes", "No", "Needs work"]),
        ("Now / Later / Never", ["Now", "Later", "Never"]),
    ]
    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("What do you want them to decide?", text: $question, axis: .vertical).lineLimit(1...3)
                }
                Section("Quick sets") {
                    ForEach(presets, id: \.0) { name, opts in
                        Button(name) {
                            options = opts.map { PollOption(text: $0) }
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                }
                Section("Options") {
                    // Each row is bound to its own identity, never to a position. Binding
                    // a text field to options[i] and then removing row i reads an index
                    // that no longer exists, which is a crash, not a glitch.
                    ForEach($options) { $opt in
                        HStack {
                            TextField("Option", text: $opt.text)
                            if options.count > 2 {
                                Button {
                                    options.removeAll { $0.id == opt.id }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < 6 { Button("Add an option") { options.append(PollOption()) } }
                }
            }
            .navigationTitle("Ask the room").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask") {
                        onAsk(question.trimmingCharacters(in: .whitespaces), cleaned)
                        dismiss()
                    }.disabled(cleaned.count < 2)
                }
            }
        }.presentationDetents([.large])
    }
}
