import SwiftUI
import UIKit
import QuickLook
import UserNotifications

struct NavRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.sec).frame(width: 24)
            Text(title).font(Theme.rowTitle).foregroundStyle(Theme.ink)
            Spacer()
            if let detail { Text(detail).font(Theme.small).foregroundStyle(Theme.dim) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
        }
        .frame(minHeight: 32)
    }
}

struct MoreView: View {
    @ObservedObject private var api = API.shared
    @State private var confirmLogout = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.s2) {
                        Initials(name: api.name.isEmpty ? "Marco" : api.name, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(api.name.isEmpty ? "Marco" : api.name).font(Theme.cardTitle).foregroundStyle(Theme.ink)
                            Text(api.email).font(Theme.meta).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                    }
                    .padding(.bottom, Theme.s2)
                    SectionHead(title: "Kaneo ACT")
                    Rows {
                        NavigationLink { BilagView() } label: { NavRow(icon: "doc.text", title: "Bilag") }.buttonStyle(Press())
                        NavigationLink { AgentsView() } label: { NavRow(icon: "person.2", title: "Agenter") }.buttonStyle(Press())
                        NavigationLink { EconomyView() } label: { NavRow(icon: "chart.bar", title: "Økonomi") }.buttonStyle(Press())
                    }
                    SectionHead(title: "Konto")
                    Rows {
                        NavigationLink { SettingsView() } label: { NavRow(icon: "gearshape", title: "Indstillinger") }.buttonStyle(Press())
                        Button { confirmLogout = true } label: {
                            HStack(spacing: Theme.s2) {
                                Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 16)).foregroundStyle(Theme.bad).frame(width: 24)
                                Text("Log ud").font(Theme.rowTitle).foregroundStyle(Theme.bad)
                                Spacer()
                            }
                            .frame(minHeight: 32)
                        }
                        .buttonStyle(Press())
                    }
                }
                .padding(Theme.s3)
            }
            .screen()
            .navigationTitle("Mere")
            .confirmationDialog("Log ud af Kaneo ACT?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log ud", role: .destructive) { Task { await API.shared.logout() } }
                Button("Annullér", role: .cancel) {}
            } message: { Text("Appens adgang slettes på serveren.") }
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
    func act(_ p: String, _ body: [String: Any] = [:], ok: String, reject: Bool = false) async -> Bool {
        do {
            try await API.shared.send(p, body)
            if reject { Haptic.reject() } else { Haptic.approve() }
            Toast.shared.show(ok)
            await load(); Router.shared.changed(); return true
        } catch { Haptic.fail(); Toast.shared.show(error.localizedDescription); return false }
    }
}

func kr(_ v: Double?, _ cur: String = "kr.") -> String {
    guard let v else { return "-" }
    return daNumber(v, decimals: v == v.rounded() ? 0 : 2) + " " + cur
}

struct KV: View {
    let k: String
    let v: String
    var tone: Tone? = nil
    var body: some View {
        HStack {
            Text(k).font(Theme.small).foregroundStyle(Theme.sec)
            Spacer()
            Text(v).font(Theme.mono(13)).foregroundStyle(tone?.color ?? Theme.ink).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Bilag
// The same buttons as bilag.js per status: kladde -> Opret kladde i Dinero; venter -> Stop / Godkend
// og bogfør; dinero_kladde (not test) -> Godkend og bogfør; Afvis while still open. Every booking
// action asks first, with the web page's own wording.
struct BilagView: View {
    @StateObject private var l = Loader("api/bilag")
    @State private var preview: URL?
    @State private var ask: (String, String, String, String, Bool)?   // question, path, toast, button, reject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s2) {
                if let e = l.error { ErrorLine(text: e) }
                if let linje = l.data["linje"].string, !linje.isEmpty { Text(clean(linje)).font(Theme.small).foregroundStyle(Theme.sec) }
                if l.data["pause"].bool { Banner(title: "Agenterne er på pause.", text: "Nye bilag læses ikke, før de kører igen.", tone: .warn) }
                if !l.loaded { SkeletonRows(count: 3) }
                else if l.data["aabne"].array.isEmpty {
                    EmptyState(icon: "doc.text", title: "Ingen bilag venter", text: "Når et købsbilag fanges fra mail eller uploades, står det her til godkendelse.")
                } else {
                    ForEach(l.data["aabne"].array, id: \.self) { b in card(b) }
                }
                if !l.data["seneste"].array.isEmpty {
                    SectionHead(title: "Seneste")
                    Rows {
                        ForEach(l.data["seneste"].array.prefix(12).map { $0 }, id: \.self) { b in
                            HStack {
                                Text("B\(b["nr"].text)").font(Theme.code).foregroundStyle(Theme.dim)
                                Text(clean(b["felter"]["leverandoer"].string ?? "Ukendt")).font(Theme.small).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer()
                                Chip(text: b["status_tekst"].text, tone: b["status"].text == "bogfoert" ? .ok : b["status"].text == "fejl" ? .bad : .neutral)
                            }
                        }
                    }
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationTitle("Bilag")
        .task { await l.load() }
        .refreshable { await l.load() }
        .quickLookPreview($preview)
        .confirmationDialog(ask?.0 ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }), titleVisibility: .visible) {
            if let a = ask {
                Button(a.3, role: a.4 ? .destructive : nil) { Task { await l.act(a.1, ok: a.2, reject: a.4) } }
                Button("Annullér", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func card(_ b: JSON) -> some View {
        let f = b["felter"], id = b["id"].text, st = b["status"].text
        let inDinero = st == "dinero_kladde" || st == "venter"
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(clean(f["leverandoer"].string ?? "Ukendt leverandør")).font(Theme.cardTitle).foregroundStyle(Theme.ink)
                    Text("B\(b["nr"].text)\(b["test"].bool ? " · test" : "")" + (b["mail"]["emne"].string.map { " · " + clean($0) } ?? ""))
                        .font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                Chip(text: b["status_tekst"].text, tone: st == "fejl" ? .bad : st == "venter" ? .warn : .neutral)
            }
            if st == "ny" {
                HStack(spacing: Theme.s1) { ProgressView().controlSize(.small); Text("Læses af den lokale model").font(Theme.small).foregroundStyle(Theme.sec) }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(kr(f["inkl"].double, f["valuta"].string ?? "DKK")).font(Theme.sans(26, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text("inkl. moms").font(Theme.meta).foregroundStyle(Theme.dim)
                }
                VStack(spacing: 6) {
                    KV(k: "Dato", v: f["dato"].text)
                    KV(k: "Moms", v: kr(f["moms"].double, f["valuta"].string ?? "DKK"))
                    KV(k: "Konto", v: f["konto"].text)
                    KV(k: "Erhvervsandel", v: (f["andel"].string ?? "100") + " %")
                    KV(k: "Betalt med", v: f["betaling"].text == "privat_kort" ? "Privat kort (60120)" : "Virksomhedskonto (55000)")
                }
            }
            if !b["fund"].array.isEmpty { Banner(title: "Koden fandt.", text: b["fund"].array.map { clean($0.text) }.joined(separator: " · "), tone: .bad) }
            if !b["graenser"].array.isEmpty { Banner(title: "Bogføres ikke af sig selv.", text: b["graenser"].array.map { clean($0.text) }.joined(separator: " · "), tone: .warn) }
            if let e = b["fejl"].string { Banner(title: "Fejl.", text: clean(e), tone: .bad) }
            if let t = b["bogfoer_efter"].date, st == "venter" { Text("Bogføres \(ACTDate.dayText(t)) kl. \(ACTDate.time(t)), medmindre du trykker Stop.").font(Theme.meta).foregroundStyle(Theme.sec) }
            HStack(spacing: Theme.s1) {
                if b["fil"].bool {
                    Button { Task { await open(id) } } label: { Image(systemName: "doc.viewfinder") }.buttonStyle(PillButton(kind: .secondary, full: false))
                }
                if st == "kladde" {
                    Button("Opret kladde") {
                        ask = ("Opret købsbilaget i Dinero som kladde med filen vedhæftet? Det bogføres ikke. Det gør du med Godkend.", "api/bilag/\(id)/dinero", "Kladden er oprettet i Dinero", "Opret kladde", false)
                    }.buttonStyle(.primary)
                } else if st == "venter" {
                    Button("Godkend og bogfør") { ask = (bookText, "api/bilag/\(id)/godkend", "Bilaget er bogført", "Godkend og bogfør", false) }.buttonStyle(.primary)
                    Button("Stop") { Task { await l.act("api/bilag/\(id)/stop", ok: "Stoppet. Bilaget venter på dig.", reject: true) } }.buttonStyle(.secondary)
                } else if st == "dinero_kladde" && !b["test"].bool {
                    Button("Godkend og bogfør") { ask = (bookText, "api/bilag/\(id)/godkend", "Bilaget er bogført", "Godkend og bogfør", false) }.buttonStyle(.primary)
                }
                if ["kladde", "dinero_kladde", "venter", "fejl"].contains(st) {
                    Button("Afvis") {
                        ask = ("Afvis bilaget?" + (inDinero ? " Kladden i Dinero slettes ikke herfra, så slet den selv i Dinero." : ""), "api/bilag/\(id)/afvis", "Bilaget er afvist", "Afvis", true)
                    }.buttonStyle(.danger)
                }
            }
        }
        .card()
    }

    private var bookText: String { "Godkend og bogfør bilaget i Dinero? Betalt med privat kort i udenlandsk valuta: modposteringen \"Betalt med privat kort\" (60120) registreres bagefter." }

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
        let paused = p.data["pause"].bool
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let e = l.error { ErrorLine(text: e) }
                VStack(alignment: .leading, spacing: Theme.s2) {
                    HStack(spacing: Theme.s1) {
                        Dot(tone: paused ? .warn : .ok)
                        Text(paused ? "Alle agenter er på pause" : "Agenterne kører").font(Theme.cardTitle).foregroundStyle(Theme.ink)
                    }
                    if paused, let t = p.data["tid"].date {
                        Text("Siden \(ACTDate.dayText(t)) kl. \(ACTDate.time(t))\(p.data["af"].string.map { " · " + $0 } ?? "")").font(Theme.meta).foregroundStyle(Theme.dim)
                    }
                    Button(paused ? "Genoptag alle agenter" : "Sæt alle agenter på pause") { confirm = true }
                        .buttonStyle(paused ? PillButton(kind: .primary) : PillButton(kind: .secondary))
                }
                .card()
                SectionHead(title: "Agenter")
                if !l.loaded { SkeletonRows(count: 5) }
                else {
                    Rows {
                        ForEach(l.data.array, id: \.self) { a in
                            NavigationLink { AgentDetail(a: a) } label: { AgentRow(a: a) }.buttonStyle(Press())
                        }
                    }
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationTitle("Agenter")
        .task { await l.load(); await p.load() }
        .refreshable { await l.load(); await p.load() }
        .confirmationDialog(paused ? "Genoptag alle agenter?" : "Sæt alle agenter på pause?", isPresented: $confirm, titleVisibility: .visible) {
            Button(paused ? "Genoptag" : "Sæt på pause", role: paused ? nil : .destructive) {
                Task { if await p.act("api/pause", ["pause": !paused], ok: paused ? "Agenterne kører igen" : "Alle agenter er på pause", reject: !paused) { await l.load() } }
            }
            Button("Annullér", role: .cancel) {}
        } message: { Text(paused ? "Timere og opgaver starter igen." : "Ingen opgaver tages, og timere springer over.") }
    }
}

func agentStatus(_ a: JSON) -> (String, Tone) {
    if !a["fejl"].array.isEmpty { return ("Fejl", .bad) }
    if a["kører"].bool { return ("Kører", .ok) }
    switch a["resultat"].string {
    case "success": return ("OK", .ok)
    case .some(let r) where !r.isEmpty: return (r, .bad)
    default: return (a["unit"].isNull ? "Manuel" : "Ukendt", .neutral)
    }
}

struct AgentRow: View {
    let a: JSON
    var body: some View {
        let st = agentStatus(a)
        HStack(spacing: Theme.s2) {
            Dot(tone: st.1)
            VStack(alignment: .leading, spacing: 2) {
                Text(a["navn"].text).font(Theme.rowTitle).foregroundStyle(Theme.ink)
                if let d = a["sidst"].date {
                    Text("Sidst \(ACTDate.ago(d))" + (a["næste"].date.map { " · næste \(ACTDate.dayText($0)) \(ACTDate.time($0))" } ?? ""))
                        .font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
                } else if let pl = a["plan"].string { Text(clean(pl)).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1) }
            }
            Spacer()
            if let n = a["aabne"].int, n > 0 { Text("\(n)").font(Theme.mono(12)).foregroundStyle(Theme.sec) }
            Chip(text: st.0, tone: st.1)
        }
    }
}

struct AgentDetail: View {
    let a: JSON
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let st = agentStatus(a)
                HStack(spacing: Theme.s1) { Chip(text: st.0, tone: st.1); if let pl = a["plan"].string { Text(clean(pl)).font(Theme.meta).foregroundStyle(Theme.dim) } }
                Text(clean(a["hvad"].text)).font(Theme.body).foregroundStyle(Theme.ink).lineSpacing(3).padding(.top, Theme.s2)
                if !a["fejl"].array.isEmpty {
                    SectionHead(title: "Fejl")
                    Rows { ForEach(a["fejl"].array.map { $0.text }, id: \.self) { f in HStack(spacing: Theme.s1) { Dot(tone: .bad); Text(clean(f)).font(Theme.small) } } }
                }
                if !a["mangler"].array.isEmpty {
                    SectionHead(title: "Mangler")
                    Rows { ForEach(a["mangler"].array.map { $0.text }, id: \.self) { f in HStack(spacing: Theme.s1) { Dot(tone: .warn); Text(clean(f)).font(Theme.small) } } }
                }
                if let s = a["seneste"].string, !s.isEmpty {
                    SectionHead(title: "Seneste")
                    Text(clean(s)).font(Theme.small).foregroundStyle(Theme.ink).lineSpacing(3).textSelection(.enabled).card()
                }
                if !a["arbejder"].array.isEmpty {
                    SectionHead(title: "Arbejder på")
                    Rows { ForEach(a["arbejder"].array, id: \.self) { c in NavigationLink { ItemDetail(c: c) } label: { ItemRow(c: c) }.buttonStyle(Press()) } }
                }
                if !a["jobs"].array.isEmpty {
                    SectionHead(title: "Seneste job")
                    Rows {
                        ForEach(a["jobs"].array, id: \.self) { j in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(clean(j["navn"].text)).font(Theme.small).foregroundStyle(Theme.ink).lineLimit(2)
                                Text([j["status"].text, j["dom"].string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.meta).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationTitle(a["navn"].text)
    }
}

// MARK: - Økonomi
// Mercury pattern: the month's result as one big number, then VAT, invoices and months as rows.
struct EconomyView: View {
    @StateObject private var l = Loader("api/oekonomi")
    @State private var busy = false

    var body: some View {
        let d = l.data["data"]
        let months = d["maaneder"].array
        let now: JSON = months.first(where: { $0["igang"].bool }) ?? months.last ?? .null
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let e = l.error { ErrorLine(text: e).padding(.bottom, Theme.s2) }
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Resultat · " + (now["navn"].string ?? now["maaned"].string ?? "denne måned")).font(Theme.sans(13, .medium)).foregroundStyle(Theme.sec)
                    Text(kr(now["resultat"].double)).font(Theme.sans(40, .semibold)).monospacedDigit()
                        .foregroundStyle((now["resultat"].double ?? 0) < 0 ? Theme.bad : Theme.ink)
                        .redacted(reason: l.loaded ? [] : .placeholder)
                    Text("Omsætning \(kr(now["omsaetning"].double)) · udgifter \(kr(now["udgifter"].double))").font(Theme.small).foregroundStyle(Theme.sec)
                    if let linje = d["linje"].string { Text(clean(linje)).font(Theme.meta).foregroundStyle(Theme.dim).padding(.top, 4) }
                }
                .card(Theme.s4)

                if !d["moms"].array.isEmpty {
                    SectionHead(title: "Moms")
                    Rows {
                        ForEach(d["moms"].array, id: \.self) { m in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m["navn"].text).font(Theme.rowTitle).foregroundStyle(Theme.ink)
                                    Text(clean(m["frist_tekst"].string ?? m["frist"].text)).font(Theme.meta)
                                        .foregroundStyle((m["dage_til_frist"].int ?? 99) < 14 && !m["afsluttet"].bool ? Theme.warn : Theme.dim)
                                }
                                Spacer()
                                Text(kr(m["at_betale"].double)).font(Theme.mono(14)).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                }
                let f = d["fakturaer"]
                SectionHead(title: "Fakturaer")
                Rows {
                    KV(k: "Åbne", v: "\(f["aabne"].array.count)")
                    KV(k: "Forfaldne", v: "\(f["forfaldne"].array.count)", tone: f["forfaldne"].array.isEmpty ? nil : .bad)
                    KV(k: "Kladder", v: f["kladder"].string ?? "0")
                    KV(k: "Betalt siden i går", v: "\(f["betalt_siden_i_gaar"].array.count)")
                    KV(k: "Rykkerudkast", v: "\(l.data["rykkere"].array.count)")
                }
                if !months.isEmpty {
                    SectionHead(title: "Måneder")
                    Rows {
                        ForEach(Array(months.reversed()), id: \.self) { m in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(m["navn"].string ?? m["maaned"].text).font(Theme.rowTitle).foregroundStyle(Theme.ink)
                                    if m["igang"].bool { Chip(text: "i gang") }
                                    Spacer()
                                    Text(kr(m["resultat"].double)).font(Theme.mono(14, .medium))
                                        .foregroundStyle((m["resultat"].double ?? 0) < 0 ? Theme.bad : Theme.ink)
                                }
                                Text("Omsætning \(kr(m["omsaetning"].double)) · udgifter \(kr(m["udgifter"].double)) · MRR \(kr(m["mrr"].double))\(m["mrr_anslaaet"].bool ? " (anslået)" : "")")
                                    .font(Theme.meta).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                if let t = l.data["sidste_koersel"]["slut"].date ?? l.data["sidste_koersel"]["start"].date {
                    Text("Hentet fra Dinero \(ACTDate.dayText(t)) kl. \(ACTDate.time(t))").font(Theme.meta).foregroundStyle(Theme.dim).padding(.top, Theme.s3)
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationTitle("Økonomi")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { busy = true; await l.act("api/oekonomi/opdater", ok: "Tallene er opdateret fra Dinero"); busy = false } } label: {
                    if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(busy)
            }
        }
        .task { await l.load() }
        .refreshable { await l.load() }
    }
}

// MARK: - Indstillinger
struct SettingsView: View {
    @ObservedObject private var lock = Lock.shared
    @ObservedObject private var api = API.shared
    @State private var status: JSON = .null
    @State private var notif = "Henter"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHead(title: "Konto")
                Rows {
                    KV(k: "Logget ind som", v: api.email.isEmpty ? api.name : api.email)
                    if let d = ACTDate.parse(api.expires) { KV(k: "Adgangen udløber", v: d.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "da_DK")))) }
                }
                SectionHead(title: "Lås")
                Rows {
                    Toggle(isOn: Binding(get: { lock.enabled }, set: { lock.set($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lås med Face ID").font(Theme.rowTitle).foregroundStyle(Theme.ink)
                            Text("Spørger, hver gang appen åbnes igen.").font(Theme.meta).foregroundStyle(Theme.dim)
                        }
                    }
                    .tint(Theme.ok).disabled(!lock.available)
                }
                SectionHead(title: "Push")
                Rows {
                    KV(k: "Notifikationer", v: notif)
                    KV(k: "Push fra ACT", v: status["apns"].bool ? "Klar" : "Ikke sat op endnu", tone: status["apns"].bool ? .ok : .warn)
                    KV(k: "Denne telefon", v: status["enhed_tilmeldt"].bool ? "Tilmeldt" : "Ikke tilmeldt")
                    Button { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: {
                        NavRow(icon: "bell", title: "Åbn iOS-indstillinger")
                    }.buttonStyle(Press())
                }
                Text("ACT sender push ved beslutninger, fejl og mails, når serveren har en APNs-nøgle.")
                    .font(Theme.meta).foregroundStyle(Theme.dim).padding(.top, Theme.s1)
                SectionHead(title: "Om")
                Rows {
                    KV(k: "Version", v: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    KV(k: "Server", v: "act.kaneo.ai")
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationTitle("Indstillinger")
        .task {
            status = (try? await API.shared.get("api/app/status")) ?? .null
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notif = s.authorizationStatus == .authorized ? "Tilladt" : s.authorizationStatus == .denied ? "Slået fra" : "Ikke spurgt"
            if s.authorizationStatus == .authorized { Push.shared.ask() }
        }
    }
}
