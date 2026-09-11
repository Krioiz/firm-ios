import SwiftUI
import UserNotifications

struct ManageView: View {
    @EnvironmentObject var store: Store
    @AppStorage("theme") private var theme = "system"
    @State private var spendCap = ""; @State private var agentCap = ""; @State private var pubCap = ""
    @State private var lastServer: (String, String, String) = ("", "", "")
    @State private var saving: String? = nil; @State private var saved: String? = nil; @State private var error: String? = nil
    @State private var pushOn = false
    @StateObject private var prov = ProvidersModel()
    var body: some View {
        List {
            Section {
                NavigationLink(value: "log") {
                    Label("Log", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("Everything the agents did, including what failed. Searchable.")
            }
            Section("Appearance") {
                Picker("Theme", selection: $theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    .pickerStyle(.segmented)
            }
            Section("Spending") {
                let spent = store.agents.reduce(0) { $0 + ($1.spend ?? 0) }
                let cap = store.settings?.limits?.daily_total_spend_cap ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Spent today"); Spacer()
                        Text("\(Fmt.money(spent)) of \(Fmt.money(cap))").foregroundStyle(.secondary).monospacedDigit() }
                    ProgressView(value: cap > 0 ? min(1, spent / cap) : 0).tint(spent / max(cap, 1) > 0.8 ? .red : .accentColor)
                }.padding(.vertical, 2)
                CapRow(title: "Daily spend cap", note: "Dollars the whole firm may spend per day",
                       key: "daily_total_spend_cap", text: $spendCap, saving: $saving, saved: $saved, error: $error, step: 0.5)
                CapRow(title: "Tasks per agent per day", note: "Any one agent stops after this many",
                       key: "per_agent_daily_cap", text: $agentCap, saving: $saving, saved: $saved, error: $error, step: 1)
            }
            Section("Publishing") {
                CapRow(title: "Amalie may publish per day", note: "Listings she can take live before asking you",
                       key: "publish_daily_cap", text: $pubCap, saving: $saving, saved: $saved, error: $error, step: 1)
            }
            Section("Subscriptions") {
                ForEach(["chatgpt", "claude"], id: \.self) { key in
                    if let p = prov.payload?.providers?[key] { UsageRow(name: key, p: p) }
                }
                if prov.payload == nil { HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) } }
                NavigationLink(value: "providers") { Label("Models for each agent", systemImage: "cpu") }
            }
            Section("Notifications") {
                HStack { Text("Push to this phone"); Spacer()
                    Text(pushOn ? "On" : "Off").foregroundStyle(pushOn ? .green : .secondary) }
                Button("Send a test") { Task { await store.sendTest(); UINotificationFeedbackGenerator().notificationOccurred(.success) } }
            }
            if let devs = store.settings?.devices, !devs.isEmpty {
                Section("Passkeys on the web") {
                    ForEach(devs) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name ?? "device")
                            Text("Enrolled \(String((d.created ?? "").prefix(10)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let timers = store.settings?.timers?.filter({ $0.next != nil }), !timers.isEmpty {
                Section("Schedules") {
                    ForEach(timers.prefix(14)) { t in
                        HStack { Text(t.unit ?? "").font(.system(size: 15))
                            Spacer(); Text(short(t.next)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
            Section { Text("The Firm \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Manage")
        .task { await prov.load() }
        .onAppear {
            fillCaps()
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DispatchQueue.main.async { pushOn = s.authorizationStatus == .authorized }
            }
        }
        // The screen can open before the settings have arrived, which used to leave the
        // boxes blank — and saving a blank box reported "Not a number" as if Marco had
        // typed something wrong. Fill them in whenever the real values land.
        .onChange(of: store.settings?.limits) { _, _ in fillCaps() }
        .alert("Could not save", isPresented: .init(get: { error != nil }, set: { _ in error = nil })) {
            Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
    }
    /// Only overwrite a box the user has not typed into.
    private func fillCaps() {
        let l = store.settings?.limits
        if spendCap.isEmpty || spendCap == lastServer.0 { spendCap = fmt(l?.daily_total_spend_cap) }
        if agentCap.isEmpty || agentCap == lastServer.1 { agentCap = fmt(l?.per_agent_daily_cap) }
        if pubCap.isEmpty   || pubCap   == lastServer.2 { pubCap   = fmt(l?.publish_daily_cap) }
        lastServer = (fmt(l?.daily_total_spend_cap), fmt(l?.per_agent_daily_cap), fmt(l?.publish_daily_cap))
    }
    private func fmt(_ v: Double?) -> String { guard let v else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
    private func short(_ s: String?) -> String {
        guard let s else { return "" }
        return s.split(separator: " ").dropFirst().prefix(2).joined(separator: " ")
    }
}

struct CapRow: View {
    let title: String; let note: String; let key: String
    /// Danish keyboards give a comma; the server only understands a dot.
    private var value: Double? {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    }
    private var bounds: (Double, Double)? {
        switch key {
        case "daily_total_spend_cap": return (0.5, 100)
        case "per_agent_daily_cap": return (1, 100)
        case "publish_daily_cap": return (0, 50)
        default: return nil
        }
    }
    /// What the server currently holds, so a Save that would change nothing stays dim.
    private var current: Double? {
        switch key {
        case "daily_total_spend_cap": return store.settings?.limits?.daily_total_spend_cap
        case "per_agent_daily_cap": return store.settings?.limits?.per_agent_daily_cap
        case "publish_daily_cap": return store.settings?.limits?.publish_daily_cap
        default: return nil
        }
    }
    private var changed: Bool { value != current }
    @Binding var text: String
    @Binding var saving: String?; @Binding var saved: String?; @Binding var error: String?
    let step: Double
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17))
            Text(note).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("", text: $text).keyboardType(.decimalPad).focused($focused)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(width: 84).padding(8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    focused = false
                    guard let v = value else { error = "Type a number first"; return }
                    if let (lo, hi) = bounds, v < lo || v > hi {
                        error = "\(title) has to be between \(Fmt.plain(lo)) and \(Fmt.plain(hi))"
                        UINotificationFeedbackGenerator().notificationOccurred(.error); return
                    }
                    saving = key
                    Task {
                        let err = await store.saveCap(key, v)
                        saving = nil
                        if let err { error = err; UINotificationFeedbackGenerator().notificationOccurred(.error) }
                        else { saved = key; UINotificationFeedbackGenerator().notificationOccurred(.success)
                               try? await Task.sleep(for: .seconds(1.5)); if saved == key { saved = nil } }
                    }
                } label: {
                    if saving == key { ProgressView().frame(width: 58) }
                    else if saved == key { Label("Saved", systemImage: "checkmark").frame(width: 58) }
                    else { Text("Save").frame(width: 58) }
                }
                .buttonStyle(.borderedProminent).tint(saved == key ? .green : .accentColor)
                .disabled(saving != nil || value == nil || !changed)
                Spacer()
            }
        }.padding(.vertical, 4)
    }
}
