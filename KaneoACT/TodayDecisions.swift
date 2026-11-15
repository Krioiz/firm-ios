import SwiftUI
import UIKit

// MARK: - Shared rows
struct ItemRow: View {
    let c: JSON
    var dateKey = "frist"
    var body: some View {
        HStack(spacing: 10) {
            BrandIcon(item: c, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(c["navn"].string ?? c["titel"].text).font(Theme.font(.subheadline, .medium)).foregroundStyle(Theme.ink).lineLimit(2)
                HStack(spacing: 6) {
                    let k = kode(c)
                    if !k.isEmpty { Text(k).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.dim) }
                    if let a = c["ansvarlig"].string, !a.isEmpty { Text(a).font(Theme.font(.caption2)).foregroundStyle(Theme.sec) }
                    if c["prio"].text == "urgent" { Pill(text: "Haster", color: Theme.bad) }
                    else if c["prio"].text == "high" { Pill(text: "Høj", color: Theme.warn) }
                }
            }
            Spacer(minLength: 4)
            if let d = c[dateKey].date {
                let over = d < Calendar.current.startOfDay(for: Date())
                Text(ACTDate.dayText(d)).font(Theme.font(.caption, .semibold)).foregroundStyle(over ? Theme.bad : Theme.sec)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ItemDetail: View {
    let c: JSON
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) { BrandIcon(item: c, size: 36); Text(kode(c)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.dim) }
                Text(c["navn"].text).font(Theme.font(.title3, .bold)).foregroundStyle(Theme.ink)
                HStack {
                    if let a = c["ansvarlig"].string { Pill(text: a) }
                    if let d = c["frist"].date { Pill(text: "Frist " + ACTDate.dayText(d), color: Theme.warn) }
                    ForEach(c["labels"].array.prefix(3).map { $0.text }, id: \.self) { Pill(text: $0) }
                }
                if !c["tekst"].text.isEmpty { Text(markdown(c["tekst"].text)).font(Theme.font(.body)).foregroundStyle(Theme.ink).textSelection(.enabled) }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle(kode(c)).navigationBarTitleDisplayMode(.inline)
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

// MARK: - I dag (ACT's Hjem)
struct TodayView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var api = API.shared

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 10 ? "Godmorgen" : h < 17 ? "God eftermiddag" : "God aften"
    }
    private var open: [JSON] { store.alle.filter { !["completed", "cancelled"].contains($0["gruppe"].text) } }
    private var mine: [JSON] {
        open.filter { $0["ansvarlig"].text == "Marco" }.sorted { ($0["frist"].string ?? "9") < ($1["frist"].string ?? "9") }.prefix(6).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(greeting), \(api.name.split(separator: " ").first.map(String.init) ?? "Marco")").font(Theme.font(.title2, .bold)).foregroundStyle(Theme.ink)
                        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "da_DK"))))
                            .font(Theme.font(.subheadline)).foregroundStyle(Theme.sec)
                    }
                    if let e = store.error { ErrorLine(text: e) }
                    if store.overblik["pause"]["pause"].bool {
                        Label("Alle agenter er på pause", systemImage: "pause.circle.fill").font(Theme.font(.subheadline, .semibold)).foregroundStyle(Theme.warn).card()
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        stat("Venter på dit ja", "\(store.decisions.count)", "checkmark.seal") { Router.shared.tab = .beslut }
                        stat("Frister 14 dage", "\(store.overblik["frister"].array.count)", "calendar") {}
                        stat("Mail venter", "\(store.mailOpen)", "envelope") { Router.shared.tab = .mail }
                        stat("AI-forbrug", "$\(fmt(store.overblik["ai"]["brugt"].double)) / $\(fmt(store.overblik["ai"]["loft"].double))", "cpu") {}
                    }
                    let fejl = store.overblik["fejl"].array
                    if !fejl.isEmpty {
                        section("Fejl hos agenter")
                        VStack(alignment: .leading, spacing: 4) { ForEach(fejl.map { $0.text }, id: \.self) { Text($0).foregroundStyle(Theme.bad) } }
                            .font(Theme.font(.footnote)).card()
                    }
                    section("Morgenbrief")
                    Text(store.overblik["brief"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Kommer kl. 07.")
                        .font(Theme.font(.footnote)).foregroundStyle(Theme.ink).textSelection(.enabled).card()
                    if let o = store.overblik["oekonomi"].string, !o.isEmpty {
                        NavigationLink { EconomyView() } label: { Text(o).font(Theme.font(.footnote)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading).card() }
                    }
                    if let s = store.overblik["salg"].string, !s.isEmpty { Text(s).font(Theme.font(.footnote)).foregroundStyle(Theme.ink).card() }
                    section("Frister")
                    list(store.overblik["frister"].array, empty: "Ingen frister de næste 14 dage.")
                    section("Tildelt dig")
                    list(mine, empty: "Intet tildelt dig.")
                }
                .padding()
            }
            .background(Theme.bg)
            .refreshable { await store.load() }
            .navigationTitle("I dag").navigationBarTitleDisplayMode(.inline)
            .overlay { if !store.loaded { ProgressView() } }
        }
    }

    private func fmt(_ d: Double?) -> String { guard let d else { return "?" }; return d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }

    private func section(_ t: String) -> some View {
        Text(t).font(Theme.font(.headline)).foregroundStyle(Theme.ink).padding(.top, 6)
    }

    private func stat(_ label: String, _ value: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(label).font(Theme.font(.caption)).foregroundStyle(Theme.sec)
                Text(value).font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit()).foregroundStyle(Theme.ink).minimumScaleFactor(0.6).lineLimit(1)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func list(_ items: [JSON], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { Text(empty).font(Theme.font(.footnote)).foregroundStyle(Theme.dim) }
            ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                NavigationLink { ItemDetail(c: c) } label: { ItemRow(c: c) }.buttonStyle(.plain)
                if i < items.count - 1 { Divider().overlay(Theme.line) }
            }
        }
        .card()
    }
}

// MARK: - Beslutninger
// The same groups and the same three actions as the web page: Godkend and Afvis go to
// POST /api/beslut/{id}, Svar to POST /api/beslut/{id}/svar. Swipe right approves, left rejects.
private func groupRx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
let decisionGroups: [(String, NSRegularExpression)] = [
    ("Opfølgning på henvendelser", groupRx("^Udkast: Opfølgning")),
    ("Opslag og annoncer", groupRx("^Udkast(?!: Opfølgning)")),
    ("Facebook-grupper", groupRx("^(FB-gruppe|Nye Facebook)")),
    ("Mails", groupRx("^Mail:")),
    ("Legater og puljer", groupRx("^Legat/pulje")),
]

func matches(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

func recommendation(_ c: JSON) -> String {
    let t = c["tekst"].text, n = c["navn"].text
    if let re = try? NSRegularExpression(pattern: "Anbefal(?:ing|et handling)\\s*:\\s*([^\\n]+)", options: [.caseInsensitive]),
       let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) {
        return String(t[r]).trimmingCharacters(in: .whitespaces)
    }
    if n.range(of: "^Udkast: Opfølgning", options: [.regularExpression, .caseInsensitive]) != nil { return "Læs udkastet. Godkend, hvis du selv vil sende det, som det står; ret det ellers først. Intet sendes automatisk." }
    if n.range(of: "^Udkast", options: [.regularExpression, .caseInsensitive]) != nil { return "Godkend, hvis teksten kan bruges, som den er. Ret den først, hvis noget skal ændres." }
    if n.range(of: "^Nye Facebook", options: [.regularExpression, .caseInsensitive]) != nil { return "Meld dig ind i de grupper, der passer, og godkend. Afvis, hvis ingen passer." }
    if n.range(of: "^FB-gruppe", options: [.regularExpression, .caseInsensitive]) != nil { return "Godkend, hvis Kaneo skal være aktiv i gruppen efter dens regler. Afvis ellers." }
    if n.range(of: "^Mail:", options: [.regularExpression, .caseInsensitive]) != nil { return "Læs mailen. Godkend, hvis den skal følges op; afvis, hvis den kan lægges væk." }
    if n.range(of: "^Legat/pulje", options: [.regularExpression, .caseInsensitive]) != nil { return "Godkend, hvis Kaneo skal søge. Afvis, hvis den ikke passer." }
    return "Godkend eller afvis."
}

@MainActor func decide(_ c: JSON, _ handling: String, tekst: String? = nil) {
    let id = c["id"].text
    Store.shared.drop(id)
    Toast.shared.show(handling == "godkend" ? "Godkendt" : "Afvist")
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    Task {
        var b: [String: Any] = ["handling": handling]
        if let tekst { b["tekst"] = tekst }
        do { try await API.shared.send("api/beslut/\(id)", b) } catch { Toast.shared.show("Det gik ikke: \(error.localizedDescription)") }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await Store.shared.load()
    }
}

struct DecisionsView: View {
    @ObservedObject private var store = Store.shared
    @State private var answering: JSON?
    @State private var opened: JSON?

    private struct Group: Identifiable { let id: String; let items: [JSON] }
    private var grouped: [Group] {
        var out = decisionGroups.map { g in Group(id: g.0, items: store.decisions.filter { matches(g.1, $0["navn"].text) }) }
        out.append(Group(id: "Andre", items: store.decisions.filter { c in !decisionGroups.contains { matches($0.1, c["navn"].text) } }))
        return out.filter { !$0.items.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if let e = store.error { ErrorLine(text: e) }
                if store.decisions.isEmpty && store.loaded {
                    VStack(spacing: 6) {
                        Text("Intet venter på dig").font(Theme.font(.headline))
                        Text("Agenterne lægger nye forslag her. Intet sendes eller postes uden dit ja.").font(Theme.font(.footnote)).foregroundStyle(Theme.sec).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40).listRowBackground(Color.clear)
                }
                ForEach(grouped) { g in
                    Section(g.id) {
                        ForEach(g.items, id: \.self) { c in
                            DecisionCard(c: c, open: { opened = c }, answer: { answering = c })
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { decide(c, "godkend") } label: { Label("Godkend", systemImage: "checkmark") }.tint(Theme.ok)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { decide(c, "afvis") } label: { Label("Afvis", systemImage: "xmark") }
                                    Button { answering = c } label: { Label("Svar", systemImage: "arrowshape.turn.up.left") }.tint(Theme.accent)
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await store.load() }
            .navigationTitle("Beslutninger")
            .navigationDestination(item: $opened) { c in DecisionDetail(c: c) }
            .sheet(item: Binding(get: { answering.map { Wrapped(json: $0) } }, set: { answering = $0?.json })) { w in
                AnswerSheet(c: w.json)
            }
        }
    }
}

struct Wrapped: Identifiable { let json: JSON; var id: String { json["id"].string ?? json["traad"].text } }

struct DecisionCard: View {
    let c: JSON
    let open: () -> Void
    let answer: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        BrandIcon(item: c, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c["navn"].text).font(Theme.font(.subheadline, .semibold)).foregroundStyle(Theme.ink).lineLimit(3).multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text(kode(c)).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.dim)
                                if let a = c["ansvarlig"].string { Text(a).font(Theme.font(.caption2)).foregroundStyle(Theme.sec) }
                                if let d = c["frist"].date { Pill(text: ACTDate.dayText(d), color: Theme.warn) }
                            }
                        }
                    }
                    if !c["tekst"].text.isEmpty {
                        Text(c["tekst"].text).font(Theme.font(.footnote)).foregroundStyle(Theme.sec).lineLimit(4).multilineTextAlignment(.leading)
                    }
                    Text(recommendation(c)).font(Theme.font(.caption)).foregroundStyle(Theme.dim).multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
            // Explicit styles: in a List row, default-styled buttons all fire on any tap in the row.
            HStack(spacing: 8) {
                Button { decide(c, "godkend") } label: { Text("Godkend").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(Theme.ok)
                Button(action: answer) { Text("Svar").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button { decide(c, "afvis") } label: { Text("Afvis").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(Theme.bad)
            }
            .font(Theme.font(.subheadline, .semibold))
        }
        .card()
    }
}

struct DecisionDetail: View {
    let c: JSON
    @State private var text = ""
    @State private var answering = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) { BrandIcon(item: c, size: 40); Text(kode(c)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.dim) }
                Text(c["navn"].text).font(Theme.font(.title3, .bold)).foregroundStyle(Theme.ink)
                Text(recommendation(c)).font(Theme.font(.footnote)).foregroundStyle(Theme.sec)
                Text("Teksten (ret den, før du godkender)").font(Theme.font(.caption, .semibold)).foregroundStyle(Theme.dim)
                TextEditor(text: $text).font(Theme.font(.body)).frame(minHeight: 260).scrollContentBackground(.hidden)
                    .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            }
            .padding()
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { decide(c, "godkend", tekst: text != c["tekst"].text ? text : nil); dismiss() } label: { Text("Godkend").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(Theme.ok)
                Button { answering = true } label: { Text("Svar").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button { decide(c, "afvis"); dismiss() } label: { Text("Afvis").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(Theme.bad)
            }
            .font(Theme.font(.headline)).padding().background(.bar)
        }
        .navigationTitle(kode(c)).navigationBarTitleDisplayMode(.inline)
        .onAppear { text = c["tekst"].text }
        .sheet(isPresented: $answering) { AnswerSheet(c: c, after: { dismiss() }) }
    }
}

struct AnswerSheet: View {
    let c: JSON
    var after: () -> Void = {}
    @State private var svar = ""
    @State private var privat = false
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var jura: Bool { (c["navn"].text + " " + c["labels"].array.map { $0.text }.joined(separator: " ")).range(of: "advokat|\\bjura\\b|juridisk|gdpr|retssag", options: [.regularExpression, .caseInsensitive]) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) { BrandIcon(item: c); Text(c["navn"].text).font(Theme.font(.subheadline, .medium)) }
                }
                Section("Svar til \(c["ansvarlig"].string ?? "agenten")") {
                    TextEditor(text: $svar).frame(minHeight: 160)
                    Toggle("Privat (skrives ikke i Kaneos hjerne)", isOn: $privat)
                    if jura { Text("Juraspørgsmål: i hjernen står kun \"besvaret, se opgaven\".").font(Theme.font(.caption)).foregroundStyle(Theme.dim) }
                }
                if let error { ErrorLine(text: error) }
            }
            .navigationTitle(kode(c)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem svar") { Task { await save() } }.disabled(busy || svar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        busy = true; error = nil
        do {
            try await API.shared.send("api/beslut/\(c["id"].text)/svar", ["svar": svar, "privat": privat])
            Store.shared.drop(c["id"].text)
            Toast.shared.show("Svar gemt hos \(kode(c))")
            dismiss(); after()
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await Store.shared.load() }
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
