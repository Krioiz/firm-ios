import SwiftUI

// Godkendelsesrunden: every open draft in ACT (Svarvagt mails, Betalingsvagt reminders, SMS replies, new-customer
// mails, LinkedIn notes and messages, invoice checks with "mangler") as one deck. Right = send, left = reject,
// tap the draft = edit and send, up = later. GET /api/app/runde and POST /api/app/runde/{id} (hq/runde.py): each
// choice goes through the source's own send path on the server; nothing new sends here. The first send in a
// session asks once more ("Send"), so a slip of the thumb sends nothing.
@MainActor final class RundeModel: ObservableObject {
    static let shared = RundeModel()
    @Published var kort: [JSON] = []
    @Published var antal = 0
    @Published var minutter = 0
    @Published var taeller: JSON = .null
    @Published var loaded = false
    @Published var error: String?
    @Published var busy = false
    /// Set after the first confirmed send; lives until the app is closed.
    var confirmed = false

    func load() async {
        do { apply(try await API.shared.get("api/app/runde")); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    func apply(_ d: JSON) {
        guard !d.isNull else { return }
        kort = d["kort"].array
        antal = d["antal"].int ?? kort.count
        minutter = d["minutter"].int ?? 0
        taeller = d["taeller"]
    }

    /// valg: send, ret, afvis, skip. True when the server took it.
    func choose(_ c: JSON, _ valg: String, tekst: String? = nil) async -> Bool {
        busy = true
        defer { busy = false }
        var b: [String: Any] = ["valg": valg, "bekraeft": true]
        if let tekst { b["tekst"] = tekst }
        let id = c["id"].text
        let before = kort
        if valg != "skip" { kort.removeAll { $0["id"].text == id } }
        do {
            let path = "api/app/runde/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
            let d = try await API.shared.send(path, b)
            apply(d["runde"])
            let v = d["valg"].text
            if v == "afvist" { Haptic.reject() } else { Haptic.approve() }
            let kilde = c["kilde"].text
            Toast.shared.show(v == "skip" ? "Lagt til senere" : v == "afvist" ? "Afvist"
                              : !c["sender"].bool ? "Markeret"
                              : (kilde == "sms" || kilde == "linkedin") ? "Godkendt og sat i kø" : "Sendt")
            Router.shared.changed()
            return true
        } catch {
            kort = before
            Haptic.fail(); Toast.shared.show(error.localizedDescription, seconds: 3.5)
            await load()
            return false
        }
    }
}

/// A choice waiting for the one extra "Send" tap.
private struct Pending: Identifiable {
    let c: JSON
    let valg: String
    let tekst: String?
    var id: String { c["id"].text + valg }
}

struct RundeView: View {
    @ObservedObject private var m = RundeModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGSize = .zero
    @State private var editing: Wrapped?
    @State private var pending: Pending?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.s2) {
                header
                if !m.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let c = m.kort.first {
                    deck(c)
                    buttons(c)
                    Text("Højre: \(c["hoejre"].string ?? "send") · venstre: afvis · op: senere · tryk: ret")
                        .font(Theme.meta).foregroundStyle(Theme.dim).frame(maxWidth: .infinity)
                        .padding(.bottom, Theme.s1)
                } else {
                    if let e = m.error { ErrorLine(text: e) }
                    EmptyState(icon: "checkmark", title: "Runden er tom", text: "Der venter ingen udkast lige nu.")
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, Theme.s3)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Runde").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Færdig") { dismiss() }.font(Theme.button) }
            }
            .task { await m.load() }
            .sheet(item: $editing) { w in
                RundeEdit(c: w.json) { t in act(w.json, "ret", tekst: t) }
            }
            .confirmationDialog(pending.map { "Send til \(clean($0.c["modtager"].text))?" } ?? "Send?",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible) {
                Button("Send") {
                    if let p = pending { m.confirmed = true; pending = nil; run(p.c, p.valg, tekst: p.tekst) }
                }
                Button("Annullér", role: .cancel) { pending = nil }
            } message: {
                Text((pending.map { clean($0.c["kanal"].text) + ". " } ?? "") + "Bagefter sender et swipe til højre direkte, så længe appen er åben.")
            }
        }
        .tint(Theme.tile)
    }

    // MARK: header: what waits, and how far the next training is
    private var header: some View {
        let n = m.taeller["n"].int ?? 0, maal = max(m.taeller["maal"].int ?? 300, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.antal > 0 ? "\(m.antal) venter · ca. \(m.minutter) min" : "Intet venter")
                    .font(Theme.sans(13, .medium)).foregroundStyle(Theme.sec)
                Spacer()
                Text("\(n) af \(maal)").font(Theme.mono(12, .medium)).monospacedDigit().foregroundStyle(Theme.dim)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.tile).frame(width: g.size.width * min(1, CGFloat(n) / CGFloat(maal)))
                }
            }
            .frame(height: 5)
            Text("\(n) af \(maal) eksempler til næste træning").font(Theme.meta).foregroundStyle(Theme.dim)
        }
        .padding(.top, Theme.s1)
        .accessibilityElement(children: .combine)
    }

    // MARK: the deck
    private func deck(_ c: JSON) -> some View {
        ZStack {
            if m.kort.count > 1 {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 1))
                    .scaleEffect(0.95).offset(y: 10).opacity(0.7)
            }
            RundeCard(c: c, drag: drag) { editing = Wrapped(json: c) }
                .id(c["id"].text)
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width) / 28))
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { g in if !m.busy { drag = g.translation } }
                        .onEnded { g in
                            let w = g.translation.width, h = g.translation.height
                            if h < -110 && abs(h) > abs(w) { act(c, "skip") }
                            else if w > 110 { act(c, "send") }
                            else if w < -110 { act(c, "afvis") }
                            else { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { drag = .zero } }
                        }
                )
                .accessibilityAction(named: Text(c["hoejre"].string ?? "Send")) { act(c, "send") }
                .accessibilityAction(named: Text("Afvis")) { act(c, "afvis") }
                .accessibilityAction(named: Text("Senere")) { act(c, "skip") }
                .accessibilityAction(named: Text("Ret")) { editing = Wrapped(json: c) }
        }
        .frame(maxHeight: .infinity)
    }

    private func buttons(_ c: JSON) -> some View {
        HStack(spacing: Theme.s2) {
            Button { act(c, "afvis") } label: { Label("Afvis", systemImage: "xmark") }
                .buttonStyle(RundeButton(kind: .reject))
            Button { act(c, "skip") } label: { Label("Senere", systemImage: "arrow.up") }
                .buttonStyle(RundeButton(kind: .later))
            Button { act(c, "send") } label: { Label(c["hoejre"].string ?? "Send", systemImage: c["sender"].bool ? "paperplane.fill" : "checkmark") }
                .buttonStyle(RundeButton(kind: .send))
        }
        .disabled(m.busy)
    }

    // MARK: actions
    private func act(_ c: JSON, _ valg: String, tekst: String? = nil) {
        if (valg == "send" || valg == "ret") && c["sender"].bool && !m.confirmed {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { drag = .zero }
            pending = Pending(c: c, valg: valg, tekst: tekst)
            return
        }
        run(c, valg, tekst: tekst)
    }

    private func run(_ c: JSON, _ valg: String, tekst: String?) {
        let out: CGSize = valg == "skip" ? CGSize(width: 0, height: -900)
            : valg == "afvis" ? CGSize(width: -700, height: 40) : CGSize(width: 700, height: 40)
        withAnimation(.easeIn(duration: 0.2)) { drag = out }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            _ = await m.choose(c, valg, tekst: tekst)
            drag = .zero
        }
    }
}

/// One card: who, to whom and how, what it answers, the draft, language and check findings.
struct RundeCard: View {
    let c: JSON
    let drag: CGSize
    let edit: () -> Void

    private var kildeNavn: String {
        ["svarvagt": "Svarvagt · mail", "betalingsvagt": "Betalingsvagt · rykker", "sms": "SMS-bro", "nykunde": "Ny kunde",
         "linkedin": "LinkedIn", "fakturatjek": "Fakturatjek"][c["kilde"].text] ?? c["kilde"].text
    }
    private var sprog: String { ["da": "dansk", "en": "engelsk"][c["sprog"].text] ?? c["sprog"].text }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                RundeIcon(ikon: c["ikon"].text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clean(c["hvem"].string ?? c["modtager"].text)).font(Theme.cardTitle).foregroundStyle(Theme.ink).lineLimit(2)
                    Text(meta).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Chip(text: sprog)
            }
            if c["sender"].bool {
                (Text("Til ").foregroundColor(Theme.sec) + Text(clean(c["modtager"].text)).font(Theme.sans(14, .semibold)).foregroundColor(Theme.ink)
                 + Text("\n" + clean(c["kanal"].text)).font(Theme.meta).foregroundColor(Theme.sec))
                    .font(Theme.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s2)
                    .background(Theme.tile.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.tile.opacity(0.3), lineWidth: 1))
            } else {
                Banner(title: "Intet sendes.", text: clean(c["kanal"].text))
            }
            if !c["emne"].text.isEmpty {
                Text(clean(c["emne"].text)).font(Theme.rowTitle).foregroundStyle(Theme.ink).lineLimit(2)
            }
            if !c["uddrag"].text.isEmpty {
                Text(clean(c["uddrag"].text)).font(Theme.small).foregroundStyle(Theme.sec).lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s2)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("Udkast").font(Theme.sans(12, .medium)).foregroundStyle(Theme.dim)
            Group {
                if c["udkast"].text.isEmpty {
                    Text("Intet udkast. Tryk for at skrive et.").foregroundStyle(Theme.dim)
                } else {
                    Text(c["udkast"].text).foregroundStyle(Theme.ink)
                }
            }
            .font(Theme.sans(15.5, .regular))
            .lineLimit(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: edit)
            .accessibilityHint("Tryk for at rette teksten")
            ForEach(c["tjek"].array.prefix(3), id: \.self) { t in
                Label(clean(t.text), systemImage: "exclamationmark.triangle").font(Theme.meta).foregroundStyle(Theme.warn).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) { stamp }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var meta: String {
        var s = kildeNavn
        if let f = c["frist"].date { s += " · frist " + ACTDate.dayText(f) + (c["frist"].text.count > 10 ? " " + ACTDate.time(f) : "") }
        if c["skippet"].bool { s += " · lagt til senere" }
        return s
    }

    @ViewBuilder private var stamp: some View {
        let up = drag.height < -40 && abs(drag.height) > abs(drag.width)
        let amount = up ? -drag.height : abs(drag.width)
        if amount > 20 {
            Text(up ? "SENERE" : drag.width > 0 ? (c["sender"].bool ? "SEND" : "OK") : "AFVIS")
                .font(Theme.sans(13, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(up ? Color.gray : drag.width > 0 ? Theme.tile : Theme.badSolid, in: RoundedRectangle(cornerRadius: 7))
                .opacity(min(1, Double(amount) / 100))
                .padding(Theme.s3)
        }
    }
}

/// The source's logo, as on Beslutninger. SMS has no brand asset: a green message symbol.
struct RundeIcon: View {
    let ikon: String
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.raised)
            switch ikon {
            case "kaneo": KTile(size: size)
            case "sms":
                Image(systemName: "message.fill").font(.system(size: size * 0.45)).foregroundStyle(Color(hex: 0x34C759))
            case "gmail", "linkedin", "dinero":
                Image("brand-" + ikon).resizable().scaledToFit().padding(size * 0.16)
            default:
                Image(systemName: "tray").font(.system(size: size * 0.42)).foregroundStyle(Theme.sec)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct RundeButton: ButtonStyle {
    enum Kind { case send, reject, later }
    let kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleOnly)
            .font(Theme.sans(16, .semibold))
            .lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(kind == .send ? Color.white : kind == .reject ? Theme.bad : Theme.sec)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(kind == .send ? Theme.tile : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(kind == .send ? Color.clear : Theme.lineStrong, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Tap on the draft: edit the text, then send it (or save it, for an invoice check).
struct RundeEdit: View {
    let c: JSON
    let done: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let maks = c["maks_tegn"].int
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.s2) {
                if c["sender"].bool {
                    Text("Til \(clean(c["modtager"].text)) · \(clean(c["kanal"].text))").font(Theme.meta).foregroundStyle(Theme.sec)
                }
                TextEditor(text: $text)
                    .font(Theme.body)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.s1)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                if let maks {
                    Text("\(text.count) af \(maks) tegn").font(Theme.meta).foregroundStyle(text.count > maks ? Theme.bad : Theme.dim)
                }
            }
            .padding(Theme.s3)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Ret udkast").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(c["sender"].bool ? "Send" : "Gem") {
                        let t = trimmed
                        dismiss()
                        Task { try? await Task.sleep(nanoseconds: 350_000_000); done(t) }
                    }
                    .font(Theme.button)
                    .disabled(trimmed.isEmpty || (maks.map { text.count > $0 } ?? false))
                }
            }
            .onAppear { text = c["udkast"].text; focused = true }
        }
        .tint(Theme.tile)
        .presentationDetents([.large])
    }
}
