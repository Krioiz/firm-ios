import SwiftUI
import UIKit
import UserNotifications

// "Til dig": everything that waits for Marco in one list, the most urgent first (a running mail
// countdown or the nearest deadline at the top). Every row has one clear main action, swipe right
// for it and left to reject or postpone, and "Mere" for the rest. Only what goes out of the house
// or cannot be undone asks first; everything else runs after 5 seconds with "Fortryd".

// MARK: - Undo: run after 5 seconds unless "Fortryd" is tapped
@MainActor final class Pending: ObservableObject {
    static let shared = Pending()
    /// Rows hidden while their action waits to run.
    @Published var hidden: Set<String> = []
    private var tokens: [String: UUID] = [:]

    func later(_ key: String, _ label: String, reject: Bool = false, _ work: @escaping () async throws -> Void) {
        if reject { Haptic.reject() } else { Haptic.approve() }
        let token = UUID()
        tokens[key] = token
        withAnimation(.easeOut(duration: 0.25)) { _ = hidden.insert(key) }
        Toast.shared.show(label, undo: { [weak self] in
            guard let self else { return }
            self.tokens[key] = nil
            withAnimation(.easeOut(duration: 0.25)) { _ = self.hidden.remove(key) }
            Haptic.tap()
        }, seconds: 5)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard tokens[key] == token else { return }
            tokens[key] = nil
            await perform(key, work)
        }
    }

    /// For what was confirmed first: runs at once.
    func now(_ key: String, _ label: String, _ work: @escaping () async throws -> Void) async -> Bool {
        withAnimation(.easeOut(duration: 0.25)) { _ = hidden.insert(key) }
        let ok = await perform(key, work)
        if ok { Haptic.approve(); Toast.shared.show(label) }
        return ok
    }

    @discardableResult
    private func perform(_ key: String, _ work: @escaping () async throws -> Void) async -> Bool {
        do {
            try await work()
            await Store.shared.load()
            hidden.remove(key)
            return true
        } catch {
            Haptic.fail()
            withAnimation { _ = hidden.remove(key) }
            Toast.shared.show("Det gik ikke. \(error.localizedDescription)")
            await Store.shared.load()
            return false
        }
    }
}

// MARK: - One list of what waits
struct WaitItem: Identifiable {
    enum Kind: Int { case mail = 0, beslutning, bilag, frist }
    let kind: Kind
    let key: String
    let json: JSON
    let title: String
    let subtitle: String
    let due: Date?
    var id: String { key }

    var kindName: String {
        switch kind { case .mail: return "Mail"; case .beslutning: return "Beslutning"; case .bilag: return "Bilag"; case .frist: return "Frist" }
    }
    var icon: String {
        switch kind { case .mail: return "tray"; case .beslutning: return "checkmark.circle"; case .bilag: return "doc.text"; case .frist: return "calendar" }
    }
    var firstName: String {
        let n = json["fra_navn"].string.flatMap { $0.isEmpty ? nil : $0 } ?? json["fra"].text
        return n.split(separator: " ").first.map(String.init) ?? n
    }
    var bilagStatus: String { json["status"].text }

    /// The one clear main action, in words that say exactly what happens.
    var primary: String? {
        switch kind {
        case .mail: return "Send svar til \(firstName)"
        case .beslutning: return "Godkend"
        case .bilag:
            switch bilagStatus {
            case "kladde": return "Opret kladde i Dinero"
            case "venter": return "Bogfør i Dinero"
            case "dinero_kladde": return json["test"].bool ? nil : "Bogfør i Dinero"
            default: return nil
            }
        case .frist: return "Marker som færdig"
        }
    }
    /// The same action in one or two words, for the button on the row.
    var short: String? {
        guard primary != nil else { return nil }
        switch kind {
        case .mail: return "Send"
        case .beslutning: return "Godkend"
        case .bilag: return bilagStatus == "kladde" ? "Opret kladde" : "Bogfør"
        case .frist: return "Færdig"
        }
    }
    /// Swipe left.
    var secondary: String {
        switch kind { case .frist: return "Udsæt til i morgen"; default: return "Afvis" }
    }
    /// Things that leave the house or cannot be undone ask first.
    var primaryNeedsConfirm: Bool { kind == .mail || (kind == .bilag && bilagStatus != "kladde") }
}

extension Store {
    static let bilagLoader = Loader("api/bilag")

    var items: [WaitItem] {
        let mails = MailModel.shared.open
        let mailItemIds = Set(mails.compactMap { $0["item_id"].string })
        let decisionIds = Set(decisions.map { $0["id"].text })
        var out: [WaitItem] = []
        for m in mails {
            let from = m["fra_navn"].string.flatMap { $0.isEmpty ? nil : $0 } ?? m["fra"].text
            out.append(WaitItem(kind: .mail, key: "m\(m["id"].text)", json: m, title: clean(m["emne"].text),
                                subtitle: "Mail fra \(from)", due: m["frist"].date))
        }
        for d in decisions {
            var sub = ["Beslutning", kode(d)]
            if let a = d["ansvarlig"].string { sub.append("fra \(a)") }
            out.append(WaitItem(kind: .beslutning, key: "d\(d["id"].text)", json: d, title: clean(d["navn"].text),
                                subtitle: sub.filter { !$0.isEmpty }.joined(separator: " · "), due: d["frist"].date))
        }
        for b in Store.bilagLoader.data["aabne"].array where ["kladde", "dinero_kladde", "venter", "fejl"].contains(b["status"].text) {
            let f = b["felter"]
            out.append(WaitItem(kind: .bilag, key: "b\(b["id"].text)", json: b,
                                title: "Bilag fra \(clean(f["leverandoer"].string ?? "ukendt leverandør"))",
                                subtitle: [kr(f["inkl"].double, f["valuta"].string ?? "DKK"), b["status"].text == "fejl" ? "skal ses" : nil].compactMap { $0 }.joined(separator: " · "),
                                due: b["bogfoer_efter"].date))
        }
        for c in overblik["frister"].array {
            let id = c["id"].text
            if decisionIds.contains(id) || mailItemIds.contains(id) { continue }
            out.append(WaitItem(kind: .frist, key: "f\(id)", json: c, title: clean(c["navn"].text),
                                subtitle: ["Frist", kode(c), c["ansvarlig"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                due: c["frist"].date))
        }
        return out.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a == b ? $0.kind.rawValue < $1.kind.rawValue : a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }

    /// Tab badge and app-icon badge.
    func updateBadge() {
        let n = items.count
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    }
}

// MARK: - Actions per item
@MainActor enum Act {
    static func primary(_ it: WaitItem) async {
        let id = it.json["id"].text
        switch it.kind {
        case .beslutning:
            Pending.shared.later(it.key, "Godkendt") { _ = try await API.shared.send("api/beslut/\(id)", ["handling": "godkend"]) }
        case .frist:
            Pending.shared.later(it.key, "Markeret som færdig") { _ = try await API.shared.send("api/opgave/\(id)", method: "PATCH", ["gruppe": "completed"]) }
        case .bilag where it.bilagStatus == "kladde":
            Pending.shared.later(it.key, "Kladden oprettes i Dinero") { _ = try await API.shared.send("api/bilag/\(id)/dinero") }
        case .bilag:
            _ = await Pending.shared.now(it.key, "Bilaget er bogført") { _ = try await API.shared.send("api/bilag/\(id)/godkend") }
        case .mail:
            _ = await Pending.shared.now(it.key, "Svaret er sendt til \(it.firstName)") {
                _ = try await API.shared.send("api/svarvagt/\(id)/send", ["bekraeft": true])
            }
        }
    }

    static func secondary(_ it: WaitItem) {
        let id = it.json["id"].text
        switch it.kind {
        case .beslutning:
            Pending.shared.later(it.key, "Afvist", reject: true) { _ = try await API.shared.send("api/beslut/\(id)", ["handling": "afvis"]) }
        case .mail:
            Pending.shared.later(it.key, "Mailen er afvist. Intet sendes", reject: true) { _ = try await API.shared.send("api/svarvagt/\(id)/afvis") }
        case .bilag:
            Pending.shared.later(it.key, "Bilaget er afvist", reject: true) { _ = try await API.shared.send("api/bilag/\(id)/afvis") }
        case .frist:
            postpone(it, days: 1)
        }
    }

    static func postpone(_ it: WaitItem, days: Int) {
        let base = max(Calendar.current.startOfDay(for: Date()), it.due.map { Calendar.current.startOfDay(for: $0) } ?? Date())
        let d = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        Pending.shared.later(it.key, "Udsat til \(ACTDate.dayText(d))", reject: true) {
            try await API.shared.send("api/opgave/\(it.json["id"].text)", method: "PATCH", ["frist": f.string(from: d)])
        }
    }

    static func confirmText(_ it: WaitItem) -> String {
        switch it.kind {
        case .mail: return "Send svaret til \(it.json["svar_til"].string ?? it.json["fra"].text)?"
        case .bilag: return "Bogfør bilaget i Dinero? Det kan ikke fortrydes herfra."
        default: return ""
        }
    }

    static func askNeo(_ it: WaitItem) {
        let q: String
        switch it.kind {
        case .mail: q = "Om mailen fra \(it.firstName) med emnet \"\(it.title)\": "
        case .beslutning: q = "Om beslutningen \(kode(it.json)) \"\(it.title)\": "
        case .bilag: q = "Om bilaget B\(it.json["nr"].text) (\(it.title.lowercased())): "
        case .frist: q = "Om opgaven \(kode(it.json)) \"\(it.title)\": "
        }
        Router.shared.askNeo(q)
    }
}

// MARK: - The screen
// Radically simple (Marco on build 102): one short line, then at most five rows, most urgent first,
// and "Vis alle". Each row: small logo, one line of title, one grey line, one button on the right.
// Everything else (Mere, Spørg Neo) sits in the row's long-press menu; search hides behind the
// magnifier. Brief, deadlines and economy live under Mere.
struct ToDigView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var mail = MailModel.shared
    @ObservedObject private var bilag = Store.bilagLoader
    @ObservedObject private var pending = Pending.shared
    @State private var confirm: WaitItem?
    @State private var answer: JSON?
    @State private var path: [NavTarget] = []
    @State private var showAll = false
    @State private var searching = false

    private var visible: [WaitItem] { store.items.filter { !pending.hidden.contains($0.key) } }

    var body: some View {
        NavigationStack(path: $path) {
            List { rows }
                .listStyle(.plain)
                .screen()
                .refreshable { await store.load() }
                .navigationTitle("Til dig")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Søg")
                    }
                }
                .navigationDestination(for: NavTarget.self) { $0.view }
                .modifier(ToDigDialogs(confirm: $confirm, answer: $answer, searching: $searching))
        }
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(Theme.sans(17, .medium)).foregroundStyle(Theme.sec)
            if store.overblik["pause"]["pause"].bool {
                Text("Agenterne er på pause.").font(Theme.small).foregroundStyle(Theme.dim)
            }
        }
        .padding(.top, Theme.s1).padding(.bottom, Theme.s3)
        .listRowInsets(EdgeInsets(top: 0, leading: Theme.s3, bottom: 0, trailing: Theme.s3))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)

        if let e = store.error { ErrorLine(text: e).plainRow() }
        if !store.loaded {
            SkeletonRows(count: 4).plainRow()
        } else {
            ForEach(showAll ? visible : Array(visible.prefix(5))) { it in
                WaitRow(it: it, open: { path.append(target(it)) }, run: { run(it) }, answer: { answer = it.json })
                    .listRowInsets(EdgeInsets(top: Theme.s2, leading: Theme.s3, bottom: Theme.s2, trailing: Theme.s3))
                    .listRowBackground(Theme.bg).listRowSeparatorTint(Theme.line)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if let p = it.primary {
                            Button { run(it) } label: { Label(p, systemImage: "checkmark") }.tint(Theme.ok)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { Act.secondary(it) } label: {
                            Label(it.secondary, systemImage: it.kind == .frist ? "clock.arrow.circlepath" : "xmark")
                        }
                        .tint(it.kind == .frist ? Theme.warn : Theme.bad)
                    }
            }
            if visible.count > 5 {
                Button { withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() } } label: {
                    Text(showAll ? "Vis færre" : "Vis alle (\(visible.count))").font(Theme.sans(15, .medium)).foregroundStyle(Theme.sec)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
    }

    private var headline: String {
        guard store.loaded else { return " " }
        switch visible.count {
        case 0: return "Alt er klaret."
        case 1: return "1 ting venter på dig."
        default: return "\(visible.count) ting venter på dig."
        }
    }

    private func run(_ it: WaitItem) {
        if it.primary == nil { return }
        if it.primaryNeedsConfirm { confirm = it } else { Task { await Act.primary(it) } }
    }
}

/// The confirm dialog, the answer sheet and the search sheet, kept out of the main body.
struct ToDigDialogs: ViewModifier {
    @Binding var confirm: WaitItem?
    @Binding var answer: JSON?
    @Binding var searching: Bool
    func body(content: Content) -> some View {
        content
            .confirmationDialog(confirm.map { Act.confirmText($0) } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let it = confirm {
                    Button(it.primary ?? "Fortsæt") { Task { await Act.primary(it) } }
                    Button("Annullér", role: .cancel) {}
                }
            }
            .sheet(item: Binding(get: { answer.map { Wrapped(json: $0) } }, set: { answer = $0?.json })) { w in AnswerSheet(c: w.json) }
            .sheet(isPresented: $searching) { SearchSheet() }
    }
}

struct SearchSheet: View {
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Text("Søg i opgaver, mails, bilag og beslutninger.").font(Theme.small).foregroundStyle(Theme.dim).plainRow()
                } else {
                    SearchResults(query: query)
                }
            }
            .listStyle(.plain)
            .screen()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Søg")
            .navigationTitle("Søg").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NavTarget.self) { $0.view }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}

/// Where a row leads.
enum NavTarget: Hashable {
    case item(JSON), mail(JSON), bilag(String), beslutning(JSON)
    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .item(let c): ItemDetail(c: c)
        case .mail(let m): MailDetail(mail: m, m: MailModel.shared)
        case .bilag(let id): BilagView(only: id)
        case .beslutning(let c): DecisionDetail(c: c)
        }
    }
}

func target(_ it: WaitItem) -> NavTarget {
    switch it.kind {
    case .mail: return .mail(it.json)
    case .beslutning: return .beslutning(it.json)
    case .bilag: return .bilag(it.json["id"].text)
    case .frist: return .item(it.json)
    }
}

struct WaitRow: View {
    let it: WaitItem
    let open: () -> Void
    let run: () -> Void
    let answer: () -> Void

    var body: some View {
        HStack(spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.title).font(Theme.rowTitle).foregroundStyle(Theme.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        if let t = tone { Dot(tone: t) }
                        Text(subline).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.s1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            if let s = it.short {
                Button(action: run) { Text(s) }
                    .buttonStyle(PillButton(kind: .primary, full: false))
                    .accessibilityLabel(it.primary ?? s)
            }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(it.kindName). \(it.title). \(subline)")
        .accessibilityAction(named: "Åbn", open)
        .accessibilityAction(named: "Spørg Neo om dette") { Act.askNeo(it) }
    }

    /// Grey line: what it is and when.
    private var subline: String {
        var p = [it.subtitle]
        if let d = it.due {
            if it.kind == .mail { p.append("svar inden \(ACTDate.time(d))") }
            else if it.kind == .bilag { p.append("bogføres \(ACTDate.dayText(d))") }
            else { p.append(ACTDate.dayText(d)) }
        }
        return p.joined(separator: " · ")
    }

    /// The only colour on the screen: a status dot. Amber = today or a running countdown, red = overdue.
    private var tone: Tone? {
        guard let d = it.due else { return nil }
        if d < (it.kind == .mail ? Date() : Calendar.current.startOfDay(for: Date())) { return .bad }
        if it.kind == .mail || Calendar.current.isDateInToday(d) { return .warn }
        return nil
    }

    @ViewBuilder private var icon: some View {
        switch it.kind {
        case .beslutning, .frist: BrandIcon(item: it.json, size: 28)
        case .mail: Initials(name: it.json["fra_navn"].string.flatMap { $0.isEmpty ? nil : $0 } ?? it.json["fra"].text, size: 28)
        case .bilag:
            ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised); Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Theme.sec) }
                .frame(width: 28, height: 28)
        }
    }

    @ViewBuilder private var menu: some View {
        Button(action: open) { Label("Åbn", systemImage: "arrow.up.right") }
        if let p = it.primary { Button(action: run) { Label(p, systemImage: "checkmark") } }
        switch it.kind {
        case .beslutning:
            Button { answer() } label: { Label("Svar med egne ord", systemImage: "arrowshape.turn.up.left") }
        case .mail:
            Button(action: open) { Label("Ret svaret først", systemImage: "pencil") }
        case .bilag where it.bilagStatus == "venter":
            Button { Pending.shared.later(it.key, "Stoppet. Bilaget venter på dig", reject: true) { _ = try await API.shared.send("api/bilag/\(it.json["id"].text)/stop") } }
                label: { Label("Stop bogføringen", systemImage: "hand.raised") }
        case .frist:
            Button { Act.postpone(it, days: 7) } label: { Label("Udsæt en uge", systemImage: "calendar.badge.clock") }
        default: EmptyView()
        }
        Button { Act.askNeo(it) } label: { Label("Spørg Neo om dette", systemImage: "waveform") }
        Divider()
        Button(role: it.kind == .frist ? nil : .destructive) { Act.secondary(it) } label: {
            Label(it.secondary, systemImage: it.kind == .frist ? "clock.arrow.circlepath" : "xmark")
        }
    }
}

// MARK: - Search across tasks, mails, bilag and decisions
struct SearchResults: View {
    let query: String
    @ObservedObject private var store = Store.shared
    @ObservedObject private var mail = MailModel.shared
    @ObservedObject private var bilag = Store.bilagLoader

    private func hit(_ parts: String...) -> Bool {
        let q = query.lowercased()
        return parts.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        let decisions = store.decisions.filter { hit($0["navn"].text, kode($0), $0["tekst"].text) }
        let decisionIds = Set(decisions.map { $0["id"].text })
        let mails = (mail.open + mail.dry + mail.done).filter { hit($0["emne"].text, $0["fra_navn"].text, $0["fra"].text, $0["udkast"].text) }
        let bilagHits = (bilag.data["aabne"].array + bilag.data["seneste"].array).filter { hit($0["felter"]["leverandoer"].text, "B" + $0["nr"].text, $0["mail"]["emne"].text) }
        let tasks = store.alle.filter { !decisionIds.contains($0["id"].text) && hit($0["navn"].text, kode($0), $0["tekst"].text) }.prefix(30)
        if decisions.isEmpty && mails.isEmpty && bilagHits.isEmpty && tasks.isEmpty {
            Text("Intet matcher \"\(query)\"").font(Theme.small).foregroundStyle(Theme.sec).plainRow()
        }
        if !decisions.isEmpty {
            Section("Beslutninger") { ForEach(decisions, id: \.self) { c in NavigationLink(value: NavTarget.beslutning(c)) { ItemRow(c: c) } } }
        }
        if !mails.isEmpty {
            Section("Mails") {
                ForEach(mails, id: \.self) { m in NavigationLink(value: NavTarget.mail(m)) { MailRow(mail: m, skew: mail.skew, countdown: m["status"].text == "venter") } }
            }
        }
        if !bilagHits.isEmpty {
            Section("Bilag") {
                ForEach(bilagHits, id: \.self) { b in
                    NavigationLink(value: NavTarget.bilag(b["id"].text)) {
                        HStack {
                            Text("Bilag fra \(clean(b["felter"]["leverandoer"].string ?? "ukendt"))").font(Theme.rowTitle).foregroundStyle(Theme.ink)
                            Spacer()
                            Chip(text: b["status_tekst"].text)
                        }
                    }
                }
            }
        }
        if !tasks.isEmpty {
            Section("Opgaver") { ForEach(Array(tasks), id: \.self) { c in NavigationLink(value: NavTarget.item(c)) { ItemRow(c: c) } } }
        }
    }
}
