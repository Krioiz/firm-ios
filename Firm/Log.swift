import SwiftUI

struct LogRow: Codable, Identifiable, Hashable {
    var id: String { (ts ?? "") + "|" + (agent ?? "") + "|" + (ref ?? "") }
    let ts: String?; let agent: String?; let kind: String?
    let text: String?; let ref: String?; let cost: Double?
}
struct LogPayload: Codable {
    let rows: [LogRow]?; let agents: [String]?; let kinds: [String]?
    let total: Int?; let shown: Int?
}

@MainActor final class LogModel: ObservableObject {
    @Published var rows: [LogRow] = []
    @Published var agents: [String] = []
    @Published var kinds: [String] = []
    @Published var total = 0
    @Published var loading = false
    var q = ""; var agent: String? = nil; var kind: String? = nil

    func load() async {
        loading = true; defer { loading = false }
        var c = URLComponents(string: "\(Store.base)/log")!
        var items = [URLQueryItem(name: "limit", value: "300")]
        if !q.isEmpty { items.append(.init(name: "q", value: q)) }
        if let a = agent { items.append(.init(name: "agent", value: a)) }
        if let k = kind { items.append(.init(name: "kind", value: k)) }
        c.queryItems = items
        var r = URLRequest(url: c.url!)
        r.setValue("FirmApp/4.9", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let p = try? JSONDecoder().decode(LogPayload.self, from: d) else { return }
        rows = p.rows ?? []
        // the filter lists come from the whole log, so only take them unfiltered
        if agent == nil && kind == nil && q.isEmpty {
            agents = p.agents ?? []; kinds = p.kinds ?? []
        }
        total = p.total ?? 0
    }
}

/// Everything the firm did, in order. Conclusions live everywhere else in the app; this is
/// the only place that shows the work — including the failures.
struct LogView: View {
    @StateObject private var model = LogModel()
    @State private var q = ""
    @State private var agent: String? = nil
    @State private var kind: String? = nil

    var body: some View {
        List {
            if !model.rows.isEmpty {
                Section {
                    ForEach(model.rows) { r in LogLine(r: r) }
                } header: {
                    Text("\(model.rows.count) of \(model.total) events")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search what they did")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Agent", selection: $agent) {
                        Text("Everyone").tag(String?.none)
                        ForEach(model.agents, id: \.self) { a in
                            Text(a.replacingOccurrences(of: "_", with: "").capitalized).tag(String?.some(a))
                        }
                    }
                    Picker("Kind", selection: $kind) {
                        Text("Everything").tag(String?.none)
                        ForEach(model.kinds, id: \.self) { k in Text(k).tag(String?.some(k)) }
                    }
                } label: {
                    Image(systemName: (agent == nil && kind == nil)
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .overlay {
            if model.rows.isEmpty && !model.loading {
                ContentUnavailableView("Nothing matches", systemImage: "magnifyingglass",
                    description: Text("No events for this search."))
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: agent) { _, v in model.agent = v; Task { await model.load() } }
        .onChange(of: kind) { _, v in model.kind = v; Task { await model.load() } }
        // let typing settle before asking the server
        .task(id: q) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.q = q; await model.load()
        }
    }
    private func reload() async {
        model.q = q; model.agent = agent; model.kind = kind
        await model.load()
    }
}

private struct LogLine: View {
    let r: LogRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text((r.agent ?? "—").replacingOccurrences(of: "_", with: "").capitalized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.agentHue(r.agent ?? ""))
                Text(r.kind ?? "").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(tint)
                Spacer()
                Text(Fmt.when(r.ts)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text(r.text ?? "").font(.system(size: 14)).foregroundStyle(.primary)
            if let ref = r.ref, !ref.isEmpty {
                Text(ref).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
    // failures should be findable by eye while scrolling past hundreds of lines
    private var tint: Color {
        switch r.kind ?? "" {
        case "failed", "cancelled", "rejected": return .red
        case "completed", "verdict", "recovered": return .green
        case "retry", "cost.corrected", "limits.updated": return .orange
        default: return .secondary
        }
    }
}
