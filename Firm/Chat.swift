import SwiftUI

struct ChatRow: Codable, Identifiable, Hashable {
    var id: String { agent ?? "" }
    let agent: String?; let pending: Bool?; let count: Int?
    let last_role: String?; let last_text: String?; let last_at: String?
}
struct ChatsPayload: Codable { let chats: [ChatRow]? }
struct Message: Codable, Identifiable, Hashable {
    var id: String { (at ?? "") + (role ?? "") + String((text ?? "").prefix(24)) }
    let role: String?; let text: String?; let at: String?; let from: String?; let cost: Double?
}
struct ChatPayload: Codable { let messages: [Message]?; let pending: Bool? }

@MainActor final class ChatModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var pending = false          // the agent is composing a reply, honestly
    @Published var sending = false
    @Published var error: String? = nil
    let agent: String
    private var poll: Task<Void, Never>? = nil
    init(agent: String) { self.agent = agent }

    func start() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                // poll quickly while a reply is being written, slowly when idle
                let fast = self?.pending == true || self?.sending == true
                try? await Task.sleep(for: .seconds(fast ? 1.5 : 6))
            }
        }
    }
    func stop() { poll?.cancel() }

    func load() async {
        var r = URLRequest(url: URL(string: "\(Store.base)/agents/\(agent)/chat")!)
        r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(ChatPayload.self, from: d) else { return }
        messages = p.messages ?? []
        pending = p.pending ?? false
        if pending == false { sending = false }
    }
    func send(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        // show it immediately; the server copy replaces it on the next poll
        messages.append(Message(role: "user", text: body, at: ISO8601DateFormatter().string(from: Date()), from: nil, cost: nil))
        var r = URLRequest(url: URL(string: "\(Store.base)/agents/\(agent)/chat")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["message": body])
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                error = (j?["error"] as? String) ?? "HTTP \(h.statusCode)"
                sending = false; UINotificationFeedbackGenerator().notificationOccurred(.error); return
            }
            pending = true
        } catch { self.error = error.localizedDescription; sending = false }
        await load()
    }
}

// ---- the list of conversations -------------------------------------------------------
struct ChatsView: View {
    @EnvironmentObject var store: Store
    @State private var chats: [ChatRow] = []
    @AppStorage("chatSeg") private var seg = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $seg) { Text("Agents").tag(0); Text("Rooms").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
            if seg == 1 { RoomsList() } else { agentList }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Chat")
    }
    private var agentList: some View {
        List {
            ForEach(chats) { c in
                if let agent = store.agents.first(where: { $0.id == c.agent }) {
                    NavigationLink(value: Conversation(agent: agent)) {
                        HStack(spacing: 12) {
                            Avatar(agent: agent)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(agent.display).font(.system(size: 17, weight: .medium))
                                    Spacer()
                                    Text(Fmt.when(c.last_at)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                if c.pending == true {
                                    HStack(spacing: 5) { TypingDots(scale: 0.7); Text("typing…").font(.system(size: 13)).foregroundStyle(.secondary) }
                                } else {
                                    Text(preview(c)).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay { if chats.isEmpty { ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right") } }
    }
    private func preview(_ c: ChatRow) -> String {
        guard let t = c.last_text, !t.isEmpty else { return "Say something" }
        return (c.last_role == "user" ? "You: " : "") + t.replacingOccurrences(of: "\n", with: " ")
    }
    private func load() async {
        var r = URLRequest(url: URL(string: "\(Store.base)/chats")!)
        r.setValue("FirmApp/3.0", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(ChatsPayload.self, from: d) else { return }
        chats = (p.chats ?? []).filter { c in store.agents.contains { $0.id == c.agent } }
    }
}
struct Conversation: Hashable { let agent: Agent }

// ---- one conversation ----------------------------------------------------------------
struct ChatView: View {
    let agent: Agent
    @EnvironmentObject var store: Store
    @StateObject private var model: ChatModel
    @State private var draft = ""
    @State private var mentionQuery: String? = nil
    @FocusState private var focused: Bool

    init(agent: Agent) { self.agent = agent; _model = StateObject(wrappedValue: ChatModel(agent: agent.id)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.messages) { m in
                            Bubble(m: m, agent: agent)
                                .contextMenu {
                                    Button { UIPasteboard.general.string = m.text ?? "" } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                        }
                        if model.pending {
                            HStack { TypingDots(); Spacer() }
                                .padding(.horizontal, 16).id("typing")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.vertical, 12)
                }
                .onChange(of: model.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: model.pending) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onAppear { proxy.scrollTo("bottom") }
            }
            if let q = mentionQuery {
                let matches = store.agents.filter { $0.id != agent.id && (q.isEmpty || $0.id.hasPrefix(q.lowercased())) }
                if !matches.isEmpty {
                    MentionBar(ids: matches.map(\.id), store: store) { complete($0) }
                }
            }
            HStack(spacing: 10) {
                TextField("Message \(agent.display)…", text: $draft, axis: .vertical)
                    .lineLimit(1...5).focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onChange(of: draft) { _, v in updateMention(v) }
                Button {
                    let t = draft; draft = ""; mentionQuery = nil
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await model.send(t) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }.disabled(!canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(agent.display).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(agent.display).font(.system(size: 16, weight: .semibold))
                    Text(model.pending ? "typing…" : agent.working ? "working" : "idle")
                        .font(.system(size: 11)).foregroundStyle(model.pending ? Color.accentColor : .secondary)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("Could not send", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.sending && !model.pending }
    private func updateMention(_ v: String) {
        // an @ that is still being typed opens the picker
        guard let at = v.lastIndex(of: "@") else { mentionQuery = nil; return }
        let tail = v[v.index(after: at)...]
        mentionQuery = tail.contains(" ") ? nil : String(tail)
    }
    private func complete(_ id: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@" + id + " "
        mentionQuery = nil
    }
}

struct Bubble: View {
    let m: Message; let agent: Agent
    private var mine: Bool { m.role == "user" }
    private var system: Bool { m.role == "system" }
    var body: some View {
        if system {
            Text(m.text ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).multilineTextAlignment(.center).padding(.horizontal, 28).padding(.vertical, 4)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 48) } else { Avatar(agent: agent, size: 26) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    highlighted(m.text ?? "")
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                        .foregroundStyle(mine ? .white : .primary)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(Fmt.when(m.at)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !mine { Spacer(minLength: 48) }
            }.padding(.horizontal, 12)
        }
    }
    /// @handles read as handles, not as plain words
    private func highlighted(_ s: String) -> Text {
        var out = Text("")
        for part in s.split(separator: " ", omittingEmptySubsequences: false) {
            let word = String(part)
            let piece = word.hasPrefix("@") && word.count > 1
                ? Text(word).bold().foregroundStyle(mine ? Color.white : Color.accentColor)
                : Text(word)
            out = out + piece + Text(" ")
        }
        return out
    }
}

struct TypingDots: View {
    var scale: CGFloat = 1
    @State private var phase = 0
    private let t = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 4 * scale) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary.opacity(phase == i ? 0.9 : 0.35))
                    .frame(width: 7 * scale, height: 7 * scale)
                    .scaleEffect(phase == i ? 1.15 : 1)
            }
        }
        .padding(.horizontal, 13 * scale).padding(.vertical, 10 * scale)
        .background(scale == 1 ? AnyShapeStyle(Color(.secondarySystemGroupedBackground)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onReceive(t) { _ in withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 } }
    }
}
