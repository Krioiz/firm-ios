import SwiftUI

struct ProviderUse: Codable, Hashable {
    let up: Bool?; let used_5h: Double?; let used_week: Double?; let reset_5h_min: Double?; let error: String?
}
struct AgentModel: Codable, Identifiable, Hashable {
    var id: String { agent }
    let agent: String; let model: String?; let fallbacks: [String]?
}
struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String { self.idField }
    private enum CodingKeys: String, CodingKey { case idField = "id", input, context, tags }
    let idField: String; let input: String?; let context: String?; let tags: String?
}
struct ProvidersPayload: Codable {
    let checked_at: String?; let providers: [String: ProviderUse]?
    let agents: [AgentModel]?; let models: [ModelInfo]?
}

@MainActor final class ProvidersModel: ObservableObject {
    @Published var payload: ProvidersPayload? = nil
    @Published var error: String? = nil
    @Published var busy: String? = nil
    func load() async {
        var r = URLRequest(url: URL(string: "\(Store.base)/providers")!)
        r.setValue("FirmApp/4.3", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return }
        payload = try? JSONDecoder().decode(ProvidersPayload.self, from: d)
    }
    func setModel(_ agent: String, _ model: String) async {
        busy = agent; defer { busy = nil }
        var r = URLRequest(url: URL(string: "\(Store.base)/agents/\(agent)/model")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("FirmApp/4.3", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { error = "Could not reach the server"; return }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            error = (j?["error"] as? String) ?? "HTTP \(h.statusCode)"
            UINotificationFeedbackGenerator().notificationOccurred(.error); return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await load()
    }
}

struct ProvidersView: View {
    @EnvironmentObject var store: Store
    @StateObject private var model = ProvidersModel()
    @State private var picking: AgentModel? = nil
    var body: some View {
        List {
            Section("Subscriptions") {
                ForEach(["chatgpt", "claude"], id: \.self) { key in
                    if let p = model.payload?.providers?[key] { UsageRow(name: key, p: p) }
                }
                if let at = model.payload?.checked_at {
                    Text("Checked \(Fmt.when(at))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Section {
                ForEach(model.payload?.agents ?? []) { a in
                    Button { picking = a } label: {
                        HStack(spacing: 12) {
                            if let ag = store.agents.first(where: { $0.id == a.agent }) { Avatar(agent: ag, size: 28) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.agent.capitalized).foregroundStyle(.primary)
                                Text(short(a.model)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.busy == a.agent { ProgressView() }
                            else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                }
            } header: { Text("Model per agent") }
            footer: { Text("Tap an agent to change which model it runs on. Fallbacks stay as they are.") }
        }
        .navigationTitle("Models & usage")
        .task { await model.load() }.refreshable { await model.load() }
        .sheet(item: $picking) { a in ModelPicker(agent: a, models: model.payload?.models ?? []) { m in
            Task { await model.setModel(a.agent, m) } } }
        .alert("Could not change it", isPresented: .init(get: { model.error != nil }, set: { _ in model.error = nil })) {
            Button("OK", role: .cancel) {} } message: { Text(model.error ?? "") }
    }
    private func short(_ m: String?) -> String { (m ?? "none").split(separator: "/").last.map(String.init) ?? "none" }
}

struct UsageRow: View {
    let name: String; let p: ProviderUse
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(p.up == true ? .green : .red).frame(width: 8, height: 8)
                Text(name == "chatgpt" ? "ChatGPT" : "Claude").font(.system(size: 16, weight: .medium))
                Spacer()
                if let m = p.reset_5h_min, m > 0 {
                    Text("resets in \(Int(m) / 60)h \(Int(m) % 60)m").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let five = p.used_5h {
                bar("5-hour window", used: five, tint: five > 80 ? .red : five > 50 ? .orange : .green)
            }
            if let week = p.used_week {
                bar("This week", used: week, tint: week > 80 ? .red : week > 50 ? .orange : .green)
            }
            if p.used_5h == nil && p.used_week == nil {
                Text("Apple does not report a quota for this one — it either answers or it doesn't.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 3)
    }
    private func bar(_ label: String, used: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(100 - used))% left").font(.caption).monospacedDigit().foregroundStyle(tint)
            }
            ProgressView(value: min(1, used / 100)).tint(tint)
        }
    }
}

struct ModelPicker: View {
    let agent: AgentModel; let models: [ModelInfo]
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Currently") { Text(agent.model ?? "none").font(.system(size: 14, design: .monospaced)) }
                if let f = agent.fallbacks, !f.isEmpty {
                    Section("Falls back to") { ForEach(f, id: \.self) { Text($0).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary) } }
                }
                Section("Available") {
                    ForEach(filtered) { m in
                        Button {
                            onPick(m.id); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(m.id).font(.system(size: 14, design: .monospaced)).foregroundStyle(.primary)
                                    if m.id == agent.model { Spacer(); Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                if let c = m.context, !c.isEmpty {
                                    Text("\(m.input ?? "") · \(c)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Filter models")
            .navigationTitle(agent.agent.capitalized).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private var filtered: [ModelInfo] {
        query.isEmpty ? models : models.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }
}
