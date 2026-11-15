import SwiftUI
import UIKit
import QuickLook
import UserNotifications

struct MoreView: View {
    @State private var confirmLogout = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { BilagView() } label: { Label("Bilag", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { AgentsView() } label: { Label("Agenter", systemImage: "person.2.wave.2") }
                    NavigationLink { EconomyView() } label: { Label("Økonomi", systemImage: "chart.bar.xaxis") }
                }
                Section {
                    NavigationLink { SettingsView() } label: { Label("Indstillinger", systemImage: "gearshape") }
                    Button(role: .destructive) { confirmLogout = true } label: { Label("Log ud", systemImage: "rectangle.portrait.and.arrow.right") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Mere")
            .confirmationDialog("Log ud af Kaneo ACT? Appens adgang slettes på serveren.", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log ud", role: .destructive) { Task { await API.shared.logout() } }
            }
        }
    }
}

// MARK: - Shared loader
@MainActor final class Loader: ObservableObject {
    let path: String
    @Published var data: JSON = .null
    @Published var error: String?
    @Published var loaded = false
    init(_ path: String) { self.path = path }
    func load() async {
        do { data = try await API.shared.get(path); error = nil } catch { self.error = error.localizedDescription }
        loaded = true
    }
    @discardableResult
    func act(_ p: String, _ body: [String: Any] = [:], ok: String) async -> Bool {
        do {
            try await API.shared.send(p, body)
            Toast.shared.show(ok); UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load(); Router.shared.changed(); return true
        } catch { Toast.shared.show(error.localizedDescription); return false }
    }
}

func kr(_ v: Double?, _ cur: String = "kr.") -> String {
    guard let v else { return "-" }
    let f = NumberFormatter(); f.locale = Locale(identifier: "da_DK"); f.numberStyle = .decimal
    f.maximumFractionDigits = v == v.rounded() ? 0 : 2; f.minimumFractionDigits = f.maximumFractionDigits
    return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " " + cur
}

// MARK: - Bilag
// The same buttons as bilag.js per status: kladde -> Opret kladde i Dinero; venter -> Stop / Godkend
// og bogfør; dinero_kladde (not test) -> Godkend og bogfør; Afvis while still open. Every booking
// action asks first, with the web page's own wording.
struct BilagView: View {
    @StateObject private var l = Loader("api/bilag")
    @State private var preview: URL?
    @State private var ask: (String, String, String, String)?   // title, path, ok text, button

    var body: some View {
        List {
            if let e = l.error { ErrorLine(text: e) }
            if let linje = l.data["linje"].string, !linje.isEmpty { Text(linje).font(Theme.font(.footnote)).foregroundStyle(Theme.sec) }
            if l.data["pause"].bool { Label("Agenterne er på pause", systemImage: "pause.circle.fill").foregroundStyle(Theme.warn) }
            Section("Åbne (\(l.data["aabne"].array.count))") {
                if l.data["aabne"].array.isEmpty && l.loaded { Text("Ingen bilag venter.").font(Theme.font(.footnote)).foregroundStyle(Theme.dim) }
                ForEach(l.data["aabne"].array, id: \.self) { b in card(b) }
            }
            Section("Seneste") {
                ForEach(l.data["seneste"].array.prefix(15).map { $0 }, id: \.self) { b in
                    HStack {
                        Text("B\(b["nr"].text) · \(b["felter"]["leverandoer"].string ?? "Ukendt")").font(Theme.font(.subheadline))
                        Spacer()
                        Pill(text: b["status_tekst"].text)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Bilag")
        .task { await l.load() }
        .refreshable { await l.load() }
        .overlay { if !l.loaded { ProgressView() } }
        .quickLookPreview($preview)
        .confirmationDialog(ask?.0 ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }), titleVisibility: .visible) {
            if let a = ask { Button(a.3) { Task { await l.act(a.1, ok: a.2) } } }
        }
    }

    @ViewBuilder private func card(_ b: JSON) -> some View {
        let f = b["felter"], id = b["id"].text, st = b["status"].text
        let inDinero = st == "dinero_kladde" || st == "venter"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("B\(b["nr"].text) · \(f["leverandoer"].string ?? "Ukendt leverandør")\(b["test"].bool ? " · TEST" : "")").font(Theme.font(.subheadline, .bold))
                Spacer()
                Pill(text: b["status_tekst"].text, color: st == "fejl" ? Theme.bad : Theme.accent)
            }
            if let m = b["mail"]["emne"].string { Text("\(b["mail"]["fra"].text): \(m)").font(Theme.font(.caption)).foregroundStyle(Theme.sec).lineLimit(2) }
            if st == "ny" {
                Text("Læses af den lokale model…").font(Theme.font(.caption)).foregroundStyle(Theme.dim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Dato", f["dato"].text)
                    row("Inkl. moms", kr(f["inkl"].double, f["valuta"].string ?? "DKK"))
                    row("Moms", kr(f["moms"].double, f["valuta"].string ?? "DKK"))
                    row("Konto", f["konto"].text)
                    row("Erhvervsandel", (f["andel"].string ?? "100") + " %")
                    row("Betalt med", f["betaling"].text == "privat_kort" ? "Privat kort (60120)" : "Virksomhedskonto (55000)")
                }
            }
            if !b["fund"].array.isEmpty { Text("Koden fandt: " + b["fund"].array.map { $0.text }.joined(separator: " · ")).font(Theme.font(.caption)).foregroundStyle(Theme.bad) }
            if !b["graenser"].array.isEmpty { Text("Bogføres ikke af sig selv: " + b["graenser"].array.map { $0.text }.joined(separator: " · ")).font(Theme.font(.caption)).foregroundStyle(Theme.warn) }
            if let e = b["fejl"].string { Text(e).font(Theme.font(.caption)).foregroundStyle(Theme.bad) }
            if let t = b["bogfoer_efter"].date, st == "venter" { Text("Bogføres \(ACTDate.dayText(t)) kl. \(ACTDate.time(t)), medmindre du trykker Stop.").font(Theme.font(.caption)).foregroundStyle(Theme.sec) }
            HStack(spacing: 8) {
                if b["fil"].bool {
                    Button("Se filen") { Task { await open(id) } }.buttonStyle(.bordered)
                }
                Spacer()
                if ["kladde", "dinero_kladde", "venter", "fejl"].contains(st) {
                    Button("Afvis") {
                        ask = ("Afvis bilaget?" + (inDinero ? " Kladden i Dinero slettes ikke herfra: slet den selv i Dinero." : ""), "api/bilag/\(id)/afvis", "Afvist", "Afvis")
                    }.buttonStyle(.bordered).tint(Theme.bad)
                }
                if st == "kladde" {
                    Button("Opret kladde i Dinero") {
                        ask = ("Opret købsbilaget i Dinero som KLADDE med filen vedhæftet? Det bogføres ikke. Det gør du med Godkend.", "api/bilag/\(id)/dinero", "Kladde oprettet i Dinero", "Opret kladde")
                    }.buttonStyle(.borderedProminent)
                } else if st == "venter" {
                    Button("Stop") { Task { await l.act("api/bilag/\(id)/stop", ok: "Stoppet: bilaget venter på din godkendelse") } }.buttonStyle(.bordered)
                    Button("Godkend og bogfør") { ask = (bookText, "api/bilag/\(id)/godkend", "Bogført", "Godkend og bogfør") }.buttonStyle(.borderedProminent)
                } else if st == "dinero_kladde" && !b["test"].bool {
                    Button("Godkend og bogfør") { ask = (bookText, "api/bilag/\(id)/godkend", "Bogført", "Godkend og bogfør") }.buttonStyle(.borderedProminent)
                }
            }
            .font(Theme.font(.footnote, .semibold))
        }
        .padding(.vertical, 4)
    }

    private var bookText: String { "Godkend og BOGFØR bilaget i Dinero? Betalt med privat kort i udenlandsk valuta: modposteringen \"Betalt med privat kort\" (60120) registreres bagefter." }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).font(Theme.font(.caption)).foregroundStyle(Theme.dim); Text(v).font(Theme.font(.caption)).foregroundStyle(Theme.ink) }
    }

    private func open(_ id: String) async {
        do {
            let (d, type) = try await API.shared.download("api/bilag/\(id)/fil")
            let ext = (type ?? "").contains("pdf") ? "pdf" : (type ?? "").contains("png") ? "png" : "jpg"
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("bilag-\(id).\(ext)")
            try d.write(to: u, options: [.atomic, .completeFileProtection])
            preview = u
        } catch { Toast.shared.show(error.localizedDescription) }
    }
}

// MARK: - Agenter
struct AgentsView: View {
    @StateObject private var l = Loader("api/agenter")
    @StateObject private var p = Loader("api/pause")
    @State private var confirm = false

    var body: some View {
        List {
            if let e = l.error { ErrorLine(text: e) }
            Section {
                let paused = p.data["pause"].bool
                VStack(alignment: .leading, spacing: 6) {
                    if paused {
                        Text("Alle agenter er på pause").font(Theme.font(.subheadline, .bold)).foregroundStyle(Theme.warn)
                        if let t = p.data["tid"].date { Text("siden \(ACTDate.dayText(t)) \(ACTDate.time(t))\(p.data["af"].string.map { " · " + $0 } ?? "")").font(Theme.font(.caption)).foregroundStyle(Theme.sec) }
                    }
                    Button(paused ? "Genoptag alle agenter" : "Sæt alle agenter på pause") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(paused ? Theme.ok : Theme.warn)
                }
                .confirmationDialog(paused ? "Genoptag alle agenter?" : "Sæt alle agenter på pause? Ingen opgaver tages, og timere springer over.", isPresented: $confirm, titleVisibility: .visible) {
                    Button(paused ? "Genoptag" : "Pause alle") {
                        Task { if await p.act("api/pause", ["pause": !paused], ok: paused ? "Agenterne kører igen" : "Alle agenter er på pause") { await l.load() } }
                    }
                }
            }
            Section("Agenter") {
                ForEach(l.data.array, id: \.self) { a in
                    NavigationLink { AgentDetail(a: a) } label: { AgentRow(a: a) }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Agenter")
        .task { await l.load(); await p.load() }
        .refreshable { await l.load(); await p.load() }
        .overlay { if !l.loaded { ProgressView() } }
    }
}

func agentStatus(_ a: JSON) -> (String, Color) {
    if !a["fejl"].array.isEmpty { return ("Fejl", Theme.bad) }
    if a["kører"].bool { return ("Kører", Theme.accent) }
    switch a["resultat"].string {
    case "success": return ("OK", Theme.ok)
    case .some(let r) where !r.isEmpty: return (r, Theme.bad)
    default: return (a["unit"].isNull ? "Manuel" : "Ukendt", Theme.dim)
    }
}

struct AgentRow: View {
    let a: JSON
    var body: some View {
        let st = agentStatus(a)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(a["navn"].text).font(Theme.font(.subheadline, .semibold))
                if let d = a["sidst"].date { Text("Sidst \(ACTDate.ago(d))" + (a["næste"].date.map { " · næste \(ACTDate.dayText($0)) \(ACTDate.time($0))" } ?? "")).font(Theme.font(.caption2)).foregroundStyle(Theme.dim) }
                else if let pl = a["plan"].string { Text(pl).font(Theme.font(.caption2)).foregroundStyle(Theme.dim) }
            }
            Spacer()
            if let n = a["aabne"].int, n > 0 { Text("\(n)").font(Theme.font(.caption, .bold)).foregroundStyle(Theme.sec) }
            Pill(text: st.0, color: st.1)
        }
    }
}

struct AgentDetail: View {
    let a: JSON
    var body: some View {
        List {
            Section { Text(a["hvad"].text).font(Theme.font(.footnote)) }
            if !a["fejl"].array.isEmpty { Section("Fejl") { ForEach(a["fejl"].array.map { $0.text }, id: \.self) { Text($0).foregroundStyle(Theme.bad).font(Theme.font(.footnote)) } } }
            if !a["mangler"].array.isEmpty { Section("Mangler") { ForEach(a["mangler"].array.map { $0.text }, id: \.self) { Text($0).font(Theme.font(.footnote)) } } }
            if let s = a["seneste"].string, !s.isEmpty { Section("Seneste") { Text(s).font(Theme.font(.footnote)).textSelection(.enabled) } }
            if !a["arbejder"].array.isEmpty {
                Section("Arbejder på") { ForEach(a["arbejder"].array, id: \.self) { c in NavigationLink { ItemDetail(c: c) } label: { ItemRow(c: c) } } }
            }
            if !a["jobs"].array.isEmpty {
                Section("Seneste job") {
                    ForEach(a["jobs"].array, id: \.self) { j in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j["navn"].text).font(Theme.font(.footnote, .medium))
                            Text([j["status"].text, j["dom"].string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.font(.caption2)).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle(a["navn"].text)
    }
}

// MARK: - Økonomi
struct EconomyView: View {
    @StateObject private var l = Loader("api/oekonomi")
    @State private var busy = false

    var body: some View {
        let d = l.data["data"]
        List {
            if let e = l.error { ErrorLine(text: e) }
            if let linje = d["linje"].string { Section { Text(linje).font(Theme.font(.footnote)) } }
            if !d["moms"].array.isEmpty {
                Section("Moms") {
                    ForEach(d["moms"].array, id: \.self) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m["navn"].text).font(Theme.font(.subheadline, .medium))
                                Text(m["frist_tekst"].string ?? m["frist"].text).font(Theme.font(.caption2)).foregroundStyle((m["dage_til_frist"].int ?? 99) < 14 && !m["afsluttet"].bool ? Theme.warn : Theme.dim)
                            }
                            Spacer()
                            Text(kr(m["at_betale"].double)).font(.system(.subheadline, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            let f = d["fakturaer"]
            Section("Fakturaer") {
                kv("Åbne", "\(f["aabne"].array.count)")
                kv("Forfaldne", "\(f["forfaldne"].array.count)", f["forfaldne"].array.isEmpty ? Theme.ink : Theme.bad)
                kv("Kladder", f["kladder"].text)
                kv("Betalt siden i går", "\(f["betalt_siden_i_gaar"].array.count)")
                kv("Rykkerudkast", "\(l.data["rykkere"].array.count)")
            }
            if !d["maaneder"].array.isEmpty {
                Section("Måneder") {
                    ForEach(d["maaneder"].array, id: \.self) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m["navn"].string ?? m["maaned"].text).font(Theme.font(.subheadline, .medium))
                                if m["igang"].bool { Pill(text: "i gang") }
                                Spacer()
                                Text(kr(m["resultat"].double)).font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                                    .foregroundStyle((m["resultat"].double ?? 0) < 0 ? Theme.bad : Theme.ok)
                            }
                            Text("Omsætning \(kr(m["omsaetning"].double)) · udgifter \(kr(m["udgifter"].double)) · MRR \(kr(m["mrr"].double))\(m["mrr_anslaaet"].bool ? " (anslået)" : "")")
                                .font(Theme.font(.caption2)).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            if let t = l.data["sidste_koersel"]["slut"].date ?? l.data["sidste_koersel"]["start"].date {
                Section { Text("Sidst hentet fra Dinero \(ACTDate.dayText(t)) kl. \(ACTDate.time(t))").font(Theme.font(.caption)).foregroundStyle(Theme.dim) }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Økonomi")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { busy = true; await l.act("api/oekonomi/opdater", ok: "Opdateret fra Dinero"); busy = false } } label: {
                    if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(busy)
            }
        }
        .task { await l.load() }
        .refreshable { await l.load() }
        .overlay { if !l.loaded { ProgressView() } }
    }

    private func kv(_ k: String, _ v: String, _ c: Color = Theme.ink) -> some View {
        HStack { Text(k).font(Theme.font(.subheadline)); Spacer(); Text(v).font(.system(.subheadline, design: .rounded).monospacedDigit()).foregroundStyle(c) }
    }
}

// MARK: - Indstillinger
struct SettingsView: View {
    @ObservedObject private var lock = Lock.shared
    @ObservedObject private var api = API.shared
    @State private var status: JSON = .null
    @State private var notif = "…"

    var body: some View {
        List {
            Section("Konto") {
                LabeledContent("Logget ind som", value: api.email.isEmpty ? api.name : api.email)
                if let d = ACTDate.parse(api.expires) { LabeledContent("Adgang udløber", value: d.formatted(date: .abbreviated, time: .omitted)) }
            }
            Section {
                Toggle("Lås med Face ID", isOn: Binding(get: { lock.enabled }, set: { lock.set($0) })).disabled(!lock.available)
            } footer: { Text("Spørger om Face ID (eller kode), hver gang appen åbnes igen.") }
            Section {
                LabeledContent("Notifikationer", value: notif)
                LabeledContent("Push fra ACT", value: status["apns"].bool ? "Klar" : "Ikke sat op endnu")
                LabeledContent("Denne telefon", value: status["enhed_tilmeldt"].bool ? "Tilmeldt" : "Ikke tilmeldt")
                Button("Åbn iOS-indstillinger") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
            } header: { Text("Push") } footer: {
                Text("ACT sender push ved beslutninger, fejl og mails, når serveren har en APNs-nøgle.")
            }
            Section("Om") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                LabeledContent("Server", value: "act.kaneo.ai")
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Indstillinger")
        .task {
            status = (try? await API.shared.get("api/app/status")) ?? .null
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notif = s.authorizationStatus == .authorized ? "Tilladt" : s.authorizationStatus == .denied ? "Slået fra" : "Ikke spurgt"
            if s.authorizationStatus == .authorized { Push.shared.ask() }
        }
    }
}
