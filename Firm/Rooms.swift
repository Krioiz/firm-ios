import SwiftUI

struct RoomMsg: Codable, Identifiable, Hashable {
    var id: String { (at ?? "") + (who ?? "") }
    let role: String?; let who: String?; let text: String?; let at: String?
}
struct Room: Codable, Identifiable, Hashable {
    let id: String; let topic: String?; let participants: [String]?; let kind: String?
    let created: String?; let count: Int?; let last: RoomMsg?; let speaking: String?
    let seed: String?; let messages: [RoomMsg]?
}
struct RoomsPayload: Codable { let rooms: [Room]?; let board: [String]? }
struct RoomPayload: Codable { let room: Room?; let speaking: String? }

@MainActor final class RoomsModel: ObservableObject {
    @Published var rooms: [Room] = []
    @Published var board: [String] = []
    @Published var error: String? = nil
    func load() async {
        guard let p: RoomsPayload = await fetch("/rooms") else { return }
        rooms = p.rooms ?? []; board = p.board ?? []
    }
    func create(topic: String, seed: String, participants: [String], board: Bool) async -> Room? {
        var r = URLRequest(url: URL(string: "\(Store.base)/rooms")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.2", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "topic": topic, "seed": seed, "participants": participants, "kind": board ? "board" : "group"])
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
        room = p.room; speaking = p.speaking
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
                                                          participants: Array(picked), board: boardMeeting) {
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
                        ForEach(model.room?.messages ?? []) { m in RoomBubble(m: m, store: store) }
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
            HStack(spacing: 10) {
                TextField("Say something to the room…", text: $draft, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    let t = draft; draft = ""
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
        .alert("Could not send", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {} } message: { Text(model.error ?? "") }
    }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.speaking == nil }
}

struct RoomBubble: View {
    let m: RoomMsg; let store: Store
    private var mine: Bool { m.who == "marco" }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) }
            else if let a = store.agents.first(where: { $0.id == m.who }) { Avatar(agent: a, size: 26) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    Text((m.who ?? "").capitalized).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.agentHue(m.who ?? ""))
                }
                Text(m.text ?? "").font(.system(size: 15)).foregroundStyle(mine ? .white : .primary)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                NavigationLink(value: r) {
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
