import SwiftUI
import UIKit

// MARK: - Shared rows
struct ItemRow: View {
    let c: JSON
    var dateKey = "frist"
    var body: some View {
        HStack(spacing: Theme.s2) {
            BrandIcon(item: c, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(clean(c["navn"].string ?? c["titel"].text)).font(Theme.rowTitle).foregroundStyle(Theme.ink).lineLimit(2)
                Text(meta).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: Theme.s1)
            if let d = c[dateKey].date {
                let over = d < Calendar.current.startOfDay(for: Date())
                Chip(text: ACTDate.dayText(d), tone: over ? .bad : Calendar.current.isDateInToday(d) ? .warn : .neutral)
            }
        }
    }
    private var meta: String {
        var p = [kode(c)]
        if let a = c["ansvarlig"].string, !a.isEmpty { p.append(a) }
        if c["prio"].text == "urgent" { p.append("haster") } else if c["prio"].text == "high" { p.append("høj prioritet") }
        return p.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ItemDetail: View {
    let c: JSON
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s2) {
                    BrandIcon(item: c, size: 44)
                    Text(kode(c)).font(Theme.code).foregroundStyle(Theme.dim)
                }
                Text(clean(c["navn"].text)).font(Theme.title).foregroundStyle(Theme.ink)
                HStack(spacing: Theme.s1) {
                    if let a = c["ansvarlig"].string { Chip(text: a) }
                    if let d = c["frist"].date { Chip(text: "Frist " + ACTDate.dayText(d), tone: d < Date() ? .bad : .warn) }
                    ForEach(c["labels"].array.prefix(3).map { $0.text }, id: \.self) { Chip(text: $0) }
                }
                if !c["tekst"].text.isEmpty {
                    Text(markdown(clean(c["tekst"].text))).font(Theme.body).foregroundStyle(Theme.ink).lineSpacing(4).textSelection(.enabled)
                        .card()
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationTitle(kode(c)).navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - I dag
// Mercury pattern: a label, one big number ("venter på dig"), a meta line, one black pill when
// something waits, then a short "Venter på dig" list, deadlines and the morning brief.
struct TodayView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var api = API.shared
    @State private var briefOpen = false

    private var open: [JSON] { store.alle.filter { !["completed", "cancelled"].contains($0["gruppe"].text) } }
    private var mine: [JSON] {
        open.filter { $0["ansvarlig"].text == "Marco" }.sorted { ($0["frist"].string ?? "9") < ($1["frist"].string ?? "9") }.prefix(5).map { $0 }
    }
    private var waiting: Int { store.decisions.count + store.mailOpen }
    private var firstName: String { api.name.split(separator: " ").first.map(String.init) ?? "Marco" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hej, \(firstName)").font(Theme.title).foregroundStyle(Theme.ink)
                        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "da_DK"))).capitalizedFirst)
                            .font(Theme.small).foregroundStyle(Theme.sec)
                    }
                    .padding(.bottom, Theme.s4)

                    if let e = store.error { ErrorLine(text: e).padding(.bottom, Theme.s2) }
                    if store.overblik["pause"]["pause"].bool {
                        Banner(title: "Alle agenter er på pause.", text: "Ingen opgaver tages, før du genoptager dem under Agenter.", tone: .warn)
                            .padding(.bottom, Theme.s2)
                    }

                    hero

                    let fejl = store.overblik["fejl"].array
                    if !fejl.isEmpty {
                        SectionHead(title: "Fejl hos agenter")
                        Rows {
                            ForEach(fejl.map { $0.text }, id: \.self) { f in
                                HStack(spacing: Theme.s1) { Dot(tone: .bad); Text(clean(f)).font(Theme.small).foregroundStyle(Theme.ink) }
                            }
                        }
                    }

                    SectionHead(title: "Venter på dig", link: store.decisions.isEmpty ? nil : "Se alle") { Router.shared.tab = .beslut }
                    if !store.loaded { SkeletonRows(count: 3) }
                    else if store.decisions.isEmpty && store.mailOpen == 0 {
                        Rows { HStack(spacing: Theme.s1) { Dot(tone: .ok); Text("Intet venter på dig. Agenterne har resten.").font(Theme.small).foregroundStyle(Theme.sec) } }
                    } else {
                        Rows {
                            if store.mailOpen > 0 {
                                Button { Router.shared.tab = .mail } label: {
                                    HStack(spacing: Theme.s2) {
                                        ZStack { RoundedRectangle(cornerRadius: 9).fill(Theme.raised); Image(systemName: "tray").foregroundStyle(Theme.sec) }.frame(width: 32, height: 32)
                                        Text(store.mailOpen == 1 ? "1 mail venter på svar" : "\(store.mailOpen) mails venter på svar").font(Theme.rowTitle).foregroundStyle(Theme.ink)
                                        Spacer(); Dot(tone: .warn)
                                    }
                                }.buttonStyle(Press())
                            }
                            ForEach(store.decisions.prefix(4).map { $0 }, id: \.self) { c in
                                NavigationLink { DecisionDetail(c: c) } label: { ItemRow(c: c) }.buttonStyle(Press())
                            }
                        }
                    }

                    SectionHead(title: "Frister", link: nil)
                    if !store.loaded { SkeletonRows(count: 2) }
                    else if store.overblik["frister"].array.isEmpty {
                        Rows { Text("Ingen frister de næste 14 dage.").font(Theme.small).foregroundStyle(Theme.sec) }
                    } else {
                        Rows {
                            ForEach(store.overblik["frister"].array.prefix(6).map { $0 }, id: \.self) { c in
                                NavigationLink { ItemDetail(c: c) } label: { ItemRow(c: c) }.buttonStyle(Press())
                            }
                        }
                    }

                    SectionHead(title: "Morgenbrief")
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        Text(clean(store.overblik["brief"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Kommer kl. 07."))
                            .font(Theme.small).foregroundStyle(Theme.ink).lineSpacing(3)
                            .lineLimit(briefOpen ? nil : 5).textSelection(.enabled)
                        if (store.overblik["brief"].string ?? "").count > 220 {
                            Button(briefOpen ? "Vis mindre" : "Vis mere") { withAnimation(.easeOut(duration: 0.2)) { briefOpen.toggle() } }
                                .font(Theme.sans(13, .medium)).foregroundStyle(Theme.sec).buttonStyle(.plain)
                        }
                    }
                    .card()

                    let oek = store.overblik["oekonomi"].string ?? "", salg = store.overblik["salg"].string ?? ""
                    if !oek.isEmpty || !salg.isEmpty {
                        SectionHead(title: "Penge og salg")
                        Rows {
                            if !oek.isEmpty {
                                NavigationLink { EconomyView() } label: {
                                    HStack { Text(clean(oek)).font(Theme.small).foregroundStyle(Theme.ink).multilineTextAlignment(.leading); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.dim) }
                                }.buttonStyle(Press())
                            }
                            if !salg.isEmpty { Text(clean(salg)).font(Theme.small).foregroundStyle(Theme.ink) }
                        }
                    }

                    if !mine.isEmpty {
                        SectionHead(title: "Tildelt dig")
                        Rows {
                            ForEach(mine, id: \.self) { c in
                                NavigationLink { ItemDetail(c: c) } label: { ItemRow(c: c) }.buttonStyle(Press())
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.s3).padding(.top, Theme.s1).padding(.bottom, Theme.s4)
            }
            .screen()
            .refreshable { await store.load() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text("Venter på dig").font(Theme.sans(13, .medium)).foregroundStyle(Theme.sec)
            Text(store.loaded ? "\(waiting)" : "0")
                .font(Theme.hero).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText()).redacted(reason: store.loaded ? [] : .placeholder)
            Text(heroMeta).font(Theme.small).foregroundStyle(Theme.sec)
            HStack(spacing: Theme.s4) {
                stat("Frister 14 dage", "\(store.overblik["frister"].array.count)")
                stat("Åbne opgaver", "\(open.count)")
                stat("AI 30 dage", "$" + daNumber(store.overblik["ai"]["brugt"].double) + " af $" + daNumber(store.overblik["ai"]["loft"].double))
            }
            .padding(.top, Theme.s2)
            if !store.decisions.isEmpty {
                Button { Haptic.tap(); Router.shared.tab = .beslut } label: {
                    Text("Tag den næste beslutning  →")
                }
                .buttonStyle(.primary).padding(.top, Theme.s3)
            } else if store.mailOpen > 0 {
                Button { Haptic.tap(); Router.shared.tab = .mail } label: { Text("Svar på mailen  →") }
                    .buttonStyle(.primary).padding(.top, Theme.s3)
            }
        }
        .card(Theme.s4)
        .animation(.easeOut(duration: 0.3), value: waiting)
    }

    private var heroMeta: String {
        let d = store.decisions.count, m = store.mailOpen
        if d == 0 && m == 0 { return "Alt er klaret." }
        return [d > 0 ? (d == 1 ? "1 beslutning" : "\(d) beslutninger") : nil, m > 0 ? (m == 1 ? "1 mail" : "\(m) mails") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.mono(15, .medium)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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
        return clean(String(t[r]).trimmingCharacters(in: .whitespaces))
    }
    func starts(_ p: String) -> Bool { n.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
    if starts("^Udkast: Opfølgning") { return "Læs udkastet. Godkend, hvis du selv vil sende det, som det står; ret det ellers først. Intet sendes automatisk." }
    if starts("^Udkast") { return "Godkend, hvis teksten kan bruges, som den er. Ret den først, hvis noget skal ændres." }
    if starts("^Nye Facebook") { return "Meld dig ind i de grupper, der passer, og godkend. Afvis, hvis ingen passer." }
    if starts("^FB-gruppe") { return "Godkend, hvis Kaneo skal være aktiv i gruppen efter dens regler. Afvis ellers." }
    if starts("^Mail:") { return "Læs mailen. Godkend, hvis den skal følges op; afvis, hvis den kan lægges væk." }
    if starts("^Legat/pulje") { return "Godkend, hvis Kaneo skal søge. Afvis, hvis den ikke passer." }
    return "Godkend eller afvis."
}

/// The first lines of the text, without markdown noise, for the card.
func excerpt(_ c: JSON) -> String {
    let lines = c["tekst"].text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("anbefal") }
        .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
    return clean(lines.prefix(3).joined(separator: " "))
}

@MainActor func decide(_ c: JSON, _ handling: String, tekst: String? = nil) {
    let id = c["id"].text
    withAnimation(.easeOut(duration: 0.25)) { Store.shared.drop(id) }
    if handling == "godkend" { Haptic.approve(); Toast.shared.show("Godkendt") } else { Haptic.reject(); Toast.shared.show("Afvist") }
    Task {
        var b: [String: Any] = ["handling": handling]
        if let tekst { b["tekst"] = tekst }
        do { try await API.shared.send("api/beslut/\(id)", b) } catch { Haptic.fail(); Toast.shared.show("Det gik ikke. \(error.localizedDescription)") }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await Store.shared.load()
    }
}

struct DecisionsView: View {
    @ObservedObject private var store = Store.shared
    @State private var answering: JSON?
    @State private var opened: JSON?

    private struct DGroup: Identifiable { let id: String; let items: [JSON] }
    private var grouped: [DGroup] {
        var out = decisionGroups.map { g in DGroup(id: g.0, items: store.decisions.filter { matches(g.1, $0["navn"].text) }) }
        out.append(DGroup(id: "Andre", items: store.decisions.filter { c in !decisionGroups.contains { matches($0.1, c["navn"].text) } }))
        return out.filter { !$0.items.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if let e = store.error { ErrorLine(text: e).plainRow() }
                if !store.loaded {
                    SkeletonRows(count: 3).plainRow()
                } else if store.decisions.isEmpty {
                    EmptyState(icon: "checkmark.circle", title: "Du er helt med",
                               text: "Agenterne lægger nye forslag her. Intet sendes eller postes uden dit ja.").plainRow()
                }
                ForEach(grouped) { g in
                    Section {
                        ForEach(g.items, id: \.self) { c in
                            DecisionCard(c: c, open: { opened = c }, answer: { answering = c })
                                .plainRow()
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { decide(c, "godkend") } label: { Label("Godkend", systemImage: "checkmark") }.tint(Theme.ok)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { decide(c, "afvis") } label: { Label("Afvis", systemImage: "xmark") }
                                    Button { answering = c } label: { Label("Svar", systemImage: "arrowshape.turn.up.left") }.tint(Color.dyn(0x585858, 0x4d4d4d))
                                }
                        }
                    } header: {
                        HStack {
                            Text(g.id).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.sec).textCase(nil)
                            Spacer()
                            Text("\(g.items.count)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .screen()
            .refreshable { await store.load() }
            .navigationTitle("Beslutninger")
            .navigationDestination(item: $opened) { c in DecisionDetail(c: c) }
            .sheet(item: Binding(get: { answering.map { Wrapped(json: $0) } }, set: { answering = $0?.json })) { w in
                AnswerSheet(c: w.json)
            }
        }
    }
}

extension View {
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: Theme.s3, bottom: 6, trailing: Theme.s3))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

struct Wrapped: Identifiable { let json: JSON; var id: String { json["id"].string ?? json["traad"].text } }

struct DecisionCard: View {
    let c: JSON
    let open: () -> Void
    let answer: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack(alignment: .top, spacing: Theme.s2) {
                    BrandIcon(item: c, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(clean(c["navn"].text)).font(Theme.cardTitle).foregroundStyle(Theme.ink).lineLimit(3).multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(kode(c)).font(Theme.code).foregroundStyle(Theme.dim)
                            if let a = c["ansvarlig"].string { Text("· " + a).font(Theme.meta).foregroundStyle(Theme.dim) }
                            if let d = c["frist"].date { Chip(text: ACTDate.dayText(d), tone: d < Date() ? .bad : .warn) }
                        }
                    }
                }
                let ex = excerpt(c)
                if !ex.isEmpty {
                    Text(ex).font(Theme.small).foregroundStyle(Theme.sec).lineLimit(3).lineSpacing(2).multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            // Explicit styles: in a List row, default-styled buttons all fire on any tap in the row.
            HStack(spacing: Theme.s1) {
                Button { decide(c, "godkend") } label: { Text("Godkend") }.buttonStyle(.primary)
                Button(action: answer) { Text("Svar") }.buttonStyle(.secondary)
                Button { decide(c, "afvis") } label: { Text("Afvis") }.buttonStyle(.danger)
            }
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
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s2) {
                    BrandIcon(item: c, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kode(c)).font(Theme.code).foregroundStyle(Theme.dim)
                        if let a = c["ansvarlig"].string { Text("Fra " + a).font(Theme.meta).foregroundStyle(Theme.sec) }
                    }
                }
                Text(clean(c["navn"].text)).font(Theme.title).foregroundStyle(Theme.ink)
                Banner(title: "Anbefaling.", text: recommendation(c))
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Teksten").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.sec)
                    Text("Ret den her, før du godkender, hvis noget skal ændres.").font(Theme.meta).foregroundStyle(Theme.dim)
                    TextEditor(text: $text).font(Theme.body).lineSpacing(3).frame(minHeight: 280).scrollContentBackground(.hidden)
                        .padding(Theme.s2).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Theme.s1) {
                Button { decide(c, "godkend", tekst: text != c["tekst"].text ? text : nil); dismiss() } label: { Text("Godkend") }.buttonStyle(.primary)
                Button { answering = true } label: { Text("Svar") }.buttonStyle(.secondary)
                Button { decide(c, "afvis"); dismiss() } label: { Text("Afvis") }.buttonStyle(.danger)
            }
            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2).background(.bar)
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
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private var jura: Bool { (c["navn"].text + " " + c["labels"].array.map { $0.text }.joined(separator: " ")).range(of: "advokat|\\bjura\\b|juridisk|gdpr|retssag", options: [.regularExpression, .caseInsensitive]) != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    HStack(spacing: Theme.s2) {
                        BrandIcon(item: c, size: 36)
                        Text(clean(c["navn"].text)).font(Theme.rowTitle).foregroundStyle(Theme.ink).lineLimit(2)
                    }
                    TextEditor(text: $svar).font(Theme.body).focused($focused).frame(minHeight: 200).scrollContentBackground(.hidden)
                        .padding(Theme.s2).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                        .overlay(alignment: .topLeading) {
                            if svar.isEmpty { Text("Skriv dit svar").font(Theme.body).foregroundStyle(Theme.dim).padding(Theme.s2).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                        }
                    Toggle(isOn: $privat) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Privat").font(Theme.rowTitle)
                            Text("Svaret skrives ikke i Kaneos hjerne.").font(Theme.meta).foregroundStyle(Theme.dim)
                        }
                    }
                    .tint(Theme.ok)
                    if jura { Banner(title: "Juraspørgsmål.", text: "I hjernen står kun \"besvaret, se opgaven\".") }
                    if let error { ErrorLine(text: error) }
                }
                .padding(Theme.s3)
            }
            .screen()
            .navigationTitle("Svar til \(c["ansvarlig"].string ?? "agenten")").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem svar") { Task { await save() } }.font(Theme.button)
                        .disabled(busy || svar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        busy = true; error = nil
        do {
            try await API.shared.send("api/beslut/\(c["id"].text)/svar", ["svar": svar, "privat": privat])
            withAnimation { Store.shared.drop(c["id"].text) }
            Haptic.approve(); Toast.shared.show("Svaret er gemt hos \(kode(c))")
            dismiss(); after()
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await Store.shared.load() }
        } catch { Haptic.fail(); self.error = error.localizedDescription }
        busy = false
    }
}
