import SwiftUI

struct InboxItem: Codable, Identifiable, Hashable {
    let id: String; let agent: String?; let kind: String?; let action: String?
    let title: String?; let detail: String?; let meta: String?; let score: Double?
    let quote: String?; let link: String?; let slug: String?; let since: String?
}
struct InboxPayload: Codable { let count: Int?; let items: [InboxItem]? }

@MainActor final class InboxModel: ObservableObject {
    @Published var items: [InboxItem] = []
    @Published var busy: Set<String> = []
    @Published var error: String? = nil
    @Published var loaded = false

    func load() async {
        var r = URLRequest(url: URL(string: "\(Store.base)/inbox")!)
        r.setValue("FirmApp/4.0", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(InboxPayload.self, from: d) else { loaded = true; return }
        items = p.items ?? []; loaded = true
    }
    /// Approve or reject. The row disappears on success; on failure it stays and says why.
    func decide(_ item: InboxItem, yes: Bool, reason: String = "") async {
        guard let agent = item.agent, let slug = item.slug else { return }
        busy.insert(item.id); defer { busy.remove(item.id) }
        let path: String, body: [String: Any]
        switch item.action {
        case "reel":
            path = "/agents/marcus/reels/\(slug)/verdict"
            body = ["verdict": yes ? "approve" : "reject", "reason": reason]
        case "build":
            if !yes { items.removeAll { $0.id == item.id }; return }   // nothing to reject against
            path = "/agents/amalie/ideas/\(slug)/build"; body = [:]
        default:
            path = "/agents/\(agent)/ideas/\(slug)/verdict"
            body = ["verdict": yes ? "keep" : "reject", "reason": reason]
        }
        var r = URLRequest(url: URL(string: Store.base + path)!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.0", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                error = (j?["error"] as? String) ?? "HTTP \(h.statusCode)"
                UINotificationFeedbackGenerator().notificationOccurred(.error); return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { items.removeAll { $0.id == item.id } }
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct InboxView: View {
    @EnvironmentObject var store: Store
    @StateObject private var model = InboxModel()
    @State private var rejecting: InboxItem? = nil
    @State private var reason = ""
    @State private var discussing: InboxItem? = nil
    @State private var goToRoom: RoomRef? = nil
    var body: some View {
        List {
            if let ref = goToRoom {
                NavigationLink(value: ref) { Label("Open the discussion", systemImage: "person.3.fill") }
            }
            ForEach(model.items) { item in
                InboxCard(item: item, busy: model.busy.contains(item.id),
                          agent: store.agents.first { $0.id == item.agent },
                          approve: { Task { await model.decide(item, yes: true) } },
                          reject: { rejecting = item; reason = "" },
                          discuss: { discussing = item })
            }
        }
        .navigationTitle("Inbox")
        .task { await model.load() }
        .refreshable { await model.load() }
        .overlay {
            if model.items.isEmpty && model.loaded {
                ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle",
                    description: Text("Everything the agents asked you has been answered."))
            }
        }
        .alert("Something went wrong", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
        .sheet(item: $discussing) { item in
            NewRoomSheet(topic: item.title ?? "Idea", seed: item.detail ?? "",
                         source: (agent: item.agent ?? "", slug: item.slug ?? "")) { room in
                goToRoom = RoomRef(id: room.id)
            }
                .environmentObject(store)
        }

        .sheet(item: $rejecting) { item in
            NavigationStack {
                Form {
                    Section("Why not?") {
                        TextField("e.g. too crowded, already exists, not my market", text: $reason, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    Section { Text("A reason teaches \(item.agent.map { $0.capitalized } ?? "the agent") your taste. It is worth the ten seconds.")
                        .font(.caption).foregroundStyle(.secondary) }
                }
                .navigationTitle("Reject").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rejecting = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Reject") {
                            let it = item, why = reason; rejecting = nil
                            Task { await model.decide(it, yes: false, reason: why) }
                        }.disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }.presentationDetents([.medium])
        }
    }
}

struct InboxCard: View {
    let item: InboxItem; let busy: Bool; let agent: Agent?
    let approve: () -> Void; let reject: () -> Void; let discuss: () -> Void
    private var verb: (String, String) { item.action == "build" ? ("Build this", "Not now") : ("Keep", "Reject") }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let a = agent { Avatar(agent: a, size: 22) }
                Text((item.agent ?? "").capitalized).font(.system(size: 13, weight: .semibold))
                Pill(text: (item.kind ?? "").capitalized, tint: .blue)
                Spacer()
                if let s = item.score { Text(item.action == "build" ? Fmt.money(s) : String(format: "%.1f", s))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary) }
            }
            Text(item.title ?? "").font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
            if let d = item.detail, !d.isEmpty {
                Text(d).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            if let m = item.meta, !m.isEmpty {
                Text(m).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let q = item.quote, !q.isEmpty {
                Text("“\(q)”").font(.system(size: 13)).italic().foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
            }
            if let l = item.link, let url = URL(string: l), !l.isEmpty {
                Link("Where this came from", destination: url).font(.system(size: 13))
            }
            HStack(spacing: 10) {
                Button(action: approve) {
                    Label(verb.0, systemImage: "checkmark").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.green).disabled(busy)
                Button(action: reject) {
                    Label(verb.1, systemImage: "xmark").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(.red).disabled(busy)
                Button(action: discuss) {
                    Image(systemName: "person.3.fill")
                }.buttonStyle(.bordered).disabled(busy)
            }
            .controlSize(.regular)
            .overlay { if busy { ProgressView() } }
            .opacity(busy ? 0.4 : 1)
        }
        .padding(.vertical, 6)
    }
}
