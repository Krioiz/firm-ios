import SwiftUI
import UIKit

// Svarvagt: the same list as ACT's Mail page (GET /api/svarvagt), a countdown to the 10-minute
// deadline as a small pill, the draft on a clean sheet, and Send / Ret og send / Afvis. Sending
// always asks first, as on the web.
@MainActor final class MailModel: ObservableObject {
    static let shared = MailModel()
    @Published var data: JSON = .null
    @Published var error: String?
    @Published var loaded = false
    /// Server clock minus phone clock, so the countdown matches the server's deadline.
    var skew: TimeInterval = 0

    var open: [JSON] { data["aabne"].array }
    var dry: [JSON] { data["toerloeb"].array }
    var done: [JSON] { data["afgjort"].array }

    func load() async {
        do {
            let d = try await API.shared.get("api/svarvagt")
            if let nu = d["nu"].date { skew = nu.timeIntervalSinceNow }
            data = d; error = nil
        } catch let e where e.isCancellation {
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    func act(_ path: String, _ body: [String: Any], ok: String, reject: Bool = false) async -> Bool {
        do {
            try await API.shared.send(path, body)
            if reject { Haptic.reject() } else { Haptic.approve() }
            Toast.shared.show(ok)
            await load(); Router.shared.changed(); return true
        } catch { Haptic.fail(); Toast.shared.show(error.localizedDescription); return false }
    }
}

/// "7:42" left, amber under 3 minutes, red and "+0:30" once the deadline has passed.
struct CountdownPill: View {
    let deadline: Date?
    let skew: TimeInterval
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let d = deadline {
                let left = Int(d.timeIntervalSince(ctx.date.addingTimeInterval(skew)))
                let a = abs(left)
                let txt = (left < 0 ? "+" : "") + String(format: "%d:%02d", a / 60, a % 60)
                HStack(spacing: 4) {
                    Image(systemName: "timer").font(.system(size: 10, weight: .semibold))
                    Text(txt).font(Theme.mono(12, .medium)).monospacedDigit()
                }
                .foregroundStyle(left < 0 ? Theme.bad : left < 180 ? Theme.warn : Theme.sec)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((left < 0 ? Theme.bad : left < 180 ? Theme.warn : Theme.sec).opacity(0.12), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(left < 0 ? "Svarfristen er overskredet med \(a / 60) min." : "\(a / 60) min. til svarfristen")
            }
        }
    }
}

struct MailView: View {
    @ObservedObject private var m = MailModel.shared
    @ObservedObject private var router = Router.shared
    @ObservedObject private var pending = Pending.shared
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            List {
                if let e = m.error { ErrorLine(text: e).plainRow() }
                if m.data["indstillinger"]["stop"].bool || m.data["pause"].bool {
                    Banner(title: m.data["pause"].bool ? "Alle agenter er på pause." : "Mailudkast er sat på pause.",
                           text: "Der laves ingen nye svarudkast eller autosvar, før det kører igen.", tone: .warn).plainRow()
                }
                if !m.loaded {
                    SkeletonRows(count: 3).plainRow()
                } else if m.open.isEmpty {
                    EmptyState(icon: "tray", title: "Alt er besvaret",
                               text: "Når en ny mail til marco@ eller kontakt@ kommer, står den her med et svarudkast.").plainRow()
                } else {
                    Section { ForEach(m.open.filter { !pending.hidden.contains("m\($0["id"].text)") }, id: \.self) { mail in row(mail, countdown: true) } } header: { head("Venter på svar", m.open.count) }
                }
                if !m.dry.isEmpty {
                    Section { ForEach(m.dry, id: \.self) { mail in row(mail, countdown: false) } } header: { head("Kun udkast, sendes ikke af sig selv", m.dry.count) }
                }
                if !m.done.isEmpty {
                    Section {
                        if showDone { ForEach(m.done, id: \.self) { mail in row(mail, countdown: false) } }
                    } header: {
                        Button { withAnimation(.easeOut(duration: 0.2)) { showDone.toggle() } } label: {
                            HStack {
                                Text("Afgjort").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.sec).textCase(nil)
                                Text("\(m.done.count)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).rotationEffect(.degrees(showDone ? 90 : 0))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .screen()
            .animation(.easeOut(duration: 0.25), value: m.open.map { $0["id"].text })
            .animation(.easeOut(duration: 0.25), value: m.loaded)
            .refreshable { await m.load() }
            .navigationTitle("Mail")
            .task { await m.load() }
            .onChange(of: router.stamp) { _, _ in Task { await m.load() } }
        }
    }

    private func head(_ t: String, _ n: Int) -> some View {
        HStack {
            Text(t).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.sec).textCase(nil)
            Spacer()
            Text("\(n)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
        }
    }

    private func row(_ mail: JSON, countdown: Bool) -> some View {
        NavigationLink { MailDetail(mail: mail, m: m) } label: { MailRow(mail: mail, skew: m.skew, countdown: countdown) }
            .listRow()
    }
}

struct MailRow: View {
    let mail: JSON
    let skew: TimeInterval
    let countdown: Bool
    var body: some View {
        HStack(alignment: .top, spacing: Theme.s2) {
            Initials(name: sender, size: RowIcon.size)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender).font(Theme.rowTitle).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: Theme.s1)
                    if let d = mail["modtaget"].date { Text(ACTDate.time(d)).font(Theme.mono(11)).foregroundStyle(Theme.dim) }
                }
                Text(clean(mail["emne"].text)).font(Theme.small).foregroundStyle(Theme.sec).lineLimit(2)
                HStack(spacing: 6) {
                    if countdown { CountdownPill(deadline: mail["frist"].date, skew: skew) }
                    if let k = mail["kategori"].string { Chip(text: k) }
                    if mail["foelsom"].bool { Chip(text: "Følsom", tone: .warn) }
                    if mail["opfoelgning"].bool { Chip(text: "Opfølgning") }
                    if !countdown { Chip(text: mail["status_tekst"].text, tone: mail["status"].text == "sendt" || mail["status"].text == "autosvar" ? .ok : .neutral) }
                }
                .padding(.top, 2)
            }
        }
    }
    private var sender: String { mail["fra_navn"].string.flatMap { $0.isEmpty ? nil : $0 } ?? mail["fra"].text }
}

struct Initials: View {
    let name: String
    var size: CGFloat = 32
    var body: some View {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0) }.joined().uppercased()
        Text(parts.isEmpty ? "?" : parts)
            .font(Theme.sans(size * 0.36, .semibold)).foregroundStyle(Color.dyn(0x585858, 0xd4d4d4))
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color.dyn(0xf0f0f0, 0x262626), Color.dyn(0xe6e6e6, 0x181818)], startPoint: .top, endPoint: .bottom), in: Circle())
            .accessibilityHidden(true)   // the name always stands next to it
    }
}

struct MailDetail: View {
    let mail: JSON
    @ObservedObject var m: MailModel
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmSend = false
    @State private var confirmReject = false
    @State private var showMail = false
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private var id: Int { mail["id"].int ?? 0 }
    private var waiting: Bool { ["venter", "toerloeb"].contains(mail["status"].text) }
    private var sender: String { mail["fra_navn"].string.flatMap { $0.isEmpty ? nil : $0 } ?? mail["fra"].text }
    private var firstName: String { sender.split(separator: " ").first.map(String.init) ?? sender }

    /// Rejecting sends nothing, so it needs no question: it runs after 5 seconds with "Fortryd".
    private func reject() {
        let mid = id
        Pending.shared.later("m\(mid)", "Mailen er afvist. Intet sendes", reject: true) {
            _ = try await API.shared.send("api/svarvagt/\(mid)/afvis")
            await MailModel.shared.load()
        }
        dismiss()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                header
                notices
                paper
                original
            }
            .padding(Theme.s3)
        }
        .screen()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if waiting {
                HStack(spacing: Theme.s1) {
                    Button { confirmSend = true } label: { Text("Send svar til \(firstName)") }.buttonStyle(.primary)
                    Button { Task { await startEdit() } } label: { Text("Ret") }.buttonStyle(PillButton(kind: .secondary, full: false))
                    Button { reject() } label: { Text("Afvis") }.buttonStyle(PillButton(kind: .danger, full: false))
                    Button { Router.shared.askNeo("Om mailen fra \(firstName) med emnet \"\(clean(mail["emne"].text))\": ") } label: {
                        Image(systemName: "waveform").frame(minWidth: 20)
                    }
                    .buttonStyle(PillButton(kind: .secondary, full: false)).accessibilityLabel("Spørg Neo om denne mail")
                }
                .disabled(busy)
                .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2).background(.bar)
            }
        }
        .confirmationDialog("Send svaret til \(mail["svar_til"].string ?? mail["fra"].text)?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send") { Task { await send(nil) } }
            Button("Annullér", role: .cancel) {}
        }

        .sheet(isPresented: $editing) {
            EditDraftSheet(to: mail["svar_til"].string ?? mail["fra"].text, subject: clean(mail["emne"].text), text: $draft) {
                await send(draft)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .top, spacing: Theme.s2) {
                Initials(name: sender, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sender).font(Theme.cardTitle).foregroundStyle(Theme.ink)
                    Text(fromLine).font(Theme.meta).foregroundStyle(Theme.dim)
                }
                Spacer()
                if mail["status"].text == "venter" { CountdownPill(deadline: mail["frist"].date, skew: m.skew) }
            }
            Text(clean(mail["emne"].text)).font(Theme.title).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                if let k = mail["kategori"].string { Chip(text: k) }
                if mail["foelsom"].bool { Chip(text: "Følsom", tone: .warn) }
                if !waiting { Chip(text: mail["status_tekst"].text, tone: .ok) }
            }
        }
    }

    private var fromLine: String {
        var s = mail["fra"].text
        if let d = mail["modtaget"].date { s += " · " + ACTDate.dayText(d) + " " + ACTDate.time(d) }
        return s
    }

    @ViewBuilder private var notices: some View {
        if mail["foelsom"].bool, let g = mail["foelsom_grund"].string, !g.isEmpty { Banner(title: "Følsom.", text: clean(g), tone: .warn) }
        if let t = autoTime { Banner(title: "Autosvar kl. \(ACTDate.time(t)).", text: "Det sendes, medmindre du handler før.", tone: .warn) }
        if !checks.isEmpty { Banner(title: "Koden fandt.", text: checks, tone: .bad) }
        if mail["mangler_viden"].bool, let x = mail["mangler"].string, !x.isEmpty { Banner(title: "Mangler viden.", text: clean(x), tone: .warn) }
    }

    private var autoTime: Date? {
        let auto = mail["autosvar"]
        guard auto["ok"].bool, !mail["auto_stop"].bool else { return nil }
        return auto["tid"].date
    }

    private var checks: String {
        mail["tjek"].array.map { t -> String in clean(t.string ?? t["tekst"].string ?? t["grund"].text) }.joined(separator: " · ")
    }

    private var draftLabel: String {
        if waiting { return "Svarudkast" }
        return mail["sendt_tekst"].isNull ? "Udkast" : "Sendt svar"
    }
    private var draftText: String { clean(mail["sendt_tekst"].string ?? mail["udkast"].text) }
    private var recipient: String { mail["svar_til"].string ?? mail["fra"].text }

    /// The draft on its own sheet of paper.
    private var paper: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Text(draftLabel).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.sec)
                Spacer()
                Text("Til " + recipient).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            Text(draftText).font(Theme.sans(15)).foregroundStyle(Theme.ink).lineSpacing(5).textSelection(.enabled)
        }
        .padding(Theme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    @ViewBuilder private var original: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { showMail.toggle() } } label: {
            HStack {
                Text(showMail ? "Skjul mailen" : "Vis mailen").font(Theme.sans(14, .medium)).foregroundStyle(Theme.sec)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).rotationEffect(.degrees(showMail ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        if showMail {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(clean(mail["tekst"].text)).font(Theme.small).foregroundStyle(Theme.sec).lineSpacing(3).textSelection(.enabled)
                if !mail["vedhaeftet"].array.isEmpty {
                    Label(mail["vedhaeftet"].array.map { $0.text }.joined(separator: ", "), systemImage: "paperclip").font(Theme.meta).foregroundStyle(Theme.dim)
                }
            }
            .card()
        }
    }

    /// As on the web: editing stops a pending autosvar first, so it cannot go out mid-edit.
    private func startEdit() async {
        draft = mail["udkast"].text; editing = true
        if mail["autosvar"]["ok"].bool && !mail["auto_stop"].bool {
            _ = try? await API.shared.send("api/svarvagt/\(id)/stop-auto", ["stop": true])
        }
    }

    private func send(_ text: String?) async {
        busy = true
        var b: [String: Any] = ["bekraeft": true]
        if let text { b["tekst"] = text }
        if await m.act("api/svarvagt/\(id)/send", b, ok: "Svaret er sendt") { editing = false; dismiss() }
        busy = false
    }
}

struct EditDraftSheet: View {
    let to: String
    let subject: String
    @Binding var text: String
    let send: () async -> Void
    @State private var confirm = false
    @State private var busy = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.s2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Til " + to).font(Theme.meta).foregroundStyle(Theme.dim)
                    Text(subject).font(Theme.rowTitle).foregroundStyle(Theme.ink).lineLimit(1)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                TextEditor(text: $text).font(Theme.sans(15)).lineSpacing(4).focused($focused).scrollContentBackground(.hidden)
            }
            .padding(Theme.s3)
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle("Ret svaret").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { confirm = true }.font(Theme.button)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Send det rettede svar til \(to)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Send") { Task { busy = true; await send(); busy = false } }
                Button("Annullér", role: .cancel) {}
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(busy)
    }
}
