import SwiftUI
import UIKit

// Svarvagt: the same list as ACT's Mail page (GET /api/svarvagt), a countdown to the 10-minute
// deadline, the draft, and Send / Ret og send / Afvis. Sending always needs a confirm, as on the web.
@MainActor final class MailModel: ObservableObject {
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
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    func act(_ path: String, _ body: [String: Any], ok: String) async -> Bool {
        do {
            try await API.shared.send(path, body)
            Toast.shared.show(ok); UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load(); Router.shared.changed(); return true
        } catch { Toast.shared.show(error.localizedDescription); return false }
    }
}

struct Countdown: View {
    let deadline: Date?
    let skew: TimeInterval
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let d = deadline {
                let left = Int(d.timeIntervalSince(ctx.date.addingTimeInterval(skew)))
                let txt = left >= 0 ? String(format: "%d:%02d", left / 60, left % 60) : "+" + String(format: "%d:%02d", -left / 60, -left % 60)
                Text(txt).font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(left < 0 ? Theme.bad : left < 180 ? Theme.warn : Theme.ok)
            }
        }
    }
}

struct MailView: View {
    @StateObject private var m = MailModel()
    @ObservedObject private var router = Router.shared
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            List {
                if let e = m.error { ErrorLine(text: e) }
                if m.data["indstillinger"]["stop"].bool || m.data["pause"].bool {
                    Label(m.data["pause"].bool ? "Alle agenter er på pause" : "Svarvagt er stoppet", systemImage: "pause.circle.fill").foregroundStyle(Theme.warn)
                }
                Section("Venter (\(m.open.count))") {
                    if m.open.isEmpty && m.loaded { Text("Ingen mails venter på svar.").font(Theme.font(.footnote)).foregroundStyle(Theme.dim) }
                    ForEach(m.open, id: \.self) { mail in
                        NavigationLink { MailDetail(mail: mail, m: m) } label: { MailRow(mail: mail, skew: m.skew, countdown: true) }
                    }
                }
                if !m.dry.isEmpty {
                    Section("Tørløb (\(m.dry.count))") {
                        ForEach(m.dry, id: \.self) { mail in
                            NavigationLink { MailDetail(mail: mail, m: m) } label: { MailRow(mail: mail, skew: m.skew, countdown: false) }
                        }
                    }
                }
                Section {
                    DisclosureGroup("Afgjort (\(m.done.count))", isExpanded: $showDone) {
                        ForEach(m.done, id: \.self) { mail in
                            NavigationLink { MailDetail(mail: mail, m: m) } label: { MailRow(mail: mail, skew: m.skew, countdown: false) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await m.load() }
            .navigationTitle("Mail")
            .task { await m.load() }
            .onChange(of: router.stamp) { _, _ in Task { await m.load() } }
            .overlay { if !m.loaded { ProgressView() } }
        }
    }
}

struct MailRow: View {
    let mail: JSON
    let skew: TimeInterval
    let countdown: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mail["fra_navn"].string.flatMap { $0.isEmpty ? nil : $0 } ?? mail["fra"].text)
                    .font(Theme.font(.subheadline, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(mail["emne"].text).font(Theme.font(.footnote)).foregroundStyle(Theme.sec).lineLimit(2)
                HStack(spacing: 6) {
                    if let k = mail["kategori"].string { Pill(text: k) }
                    if mail["foelsom"].bool { Pill(text: "Følsom", color: Theme.warn) }
                    if mail["opfoelgning"].bool { Pill(text: "Opfølgning", color: Theme.accent) }
                    if !countdown { Pill(text: mail["status_tekst"].text) }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if countdown { Countdown(deadline: mail["frist"].date, skew: skew) }
                if let d = mail["modtaget"].date { Text(ACTDate.time(d)).font(Theme.font(.caption2)).foregroundStyle(Theme.dim) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MailDetail: View {
    let mail: JSON
    @ObservedObject var m: MailModel
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmSend = false
    @State private var confirmReject = false
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private var id: Int { mail["id"].int ?? 0 }
    private var waiting: Bool { ["venter", "toerloeb"].contains(mail["status"].text) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mail["emne"].text).font(Theme.font(.title3, .bold)).foregroundStyle(Theme.ink)
                    Text("\(mail["fra_navn"].text) <\(mail["fra"].text)>").font(Theme.font(.footnote)).foregroundStyle(Theme.sec)
                    HStack(spacing: 6) {
                        if let k = mail["kategori"].string { Pill(text: k) }
                        if mail["foelsom"].bool { Pill(text: "Følsom" + (mail["foelsom_grund"].string.map { ": " + $0 } ?? ""), color: Theme.warn) }
                        if mail["status"].text == "venter" { Countdown(deadline: mail["frist"].date, skew: m.skew) }
                    }
                }
                let auto = mail["autosvar"]
                if auto["ok"].bool && !mail["auto_stop"].bool, let t = auto["tid"].date {
                    Label("Autosvar sendes kl. \(ACTDate.time(t)), medmindre du handler.", systemImage: "clock.arrow.circlepath").font(Theme.font(.footnote)).foregroundStyle(Theme.warn)
                }
                let tjek = mail["tjek"].array
                if !tjek.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Koden fandt").font(Theme.font(.caption, .bold))
                        ForEach(Array(tjek.enumerated()), id: \.offset) { _, t in Text(t.string ?? t["tekst"].string ?? t["grund"].text).font(Theme.font(.footnote)) }
                    }
                    .foregroundStyle(Theme.bad).card()
                }
                if mail["mangler_viden"].bool, let x = mail["mangler"].string, !x.isEmpty {
                    Label("Mangler viden: \(x)", systemImage: "questionmark.circle").font(Theme.font(.footnote)).foregroundStyle(Theme.warn)
                }
                Text(waiting ? "Svarudkast" : (mail["sendt_tekst"].isNull ? "Udkast" : "Sendt svar")).font(Theme.font(.headline))
                if editing {
                    TextEditor(text: $draft).font(Theme.font(.body)).frame(minHeight: 240).scrollContentBackground(.hidden)
                        .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent))
                } else {
                    Text(mail["sendt_tekst"].string ?? mail["udkast"].text).font(Theme.font(.body)).foregroundStyle(Theme.ink).textSelection(.enabled).card()
                }
                Text("Mailen").font(Theme.font(.headline))
                Text(mail["tekst"].text).font(Theme.font(.footnote)).foregroundStyle(Theme.sec).textSelection(.enabled).card()
                if !mail["vedhaeftet"].array.isEmpty {
                    Label(mail["vedhaeftet"].array.map { $0.text }.joined(separator: ", "), systemImage: "paperclip").font(Theme.font(.caption)).foregroundStyle(Theme.dim)
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle(mail["fra_navn"].string ?? "Mail").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if waiting {
                HStack(spacing: 8) {
                    if editing {
                        Button("Annullér") { editing = false }.buttonStyle(.bordered)
                        Button { confirmSend = true } label: { Text("Send rettet").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    } else {
                        Button { confirmSend = true } label: { Text("Send").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                        Button { Task { await startEdit() } } label: { Text("Ret og send").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                        Button { confirmReject = true } label: { Text("Afvis").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(Theme.bad)
                    }
                }
                .font(Theme.font(.subheadline, .semibold)).disabled(busy).padding().background(.bar)
            }
        }
        .confirmationDialog("Send svaret til \(mail["svar_til"].string ?? mail["fra"].text)?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send") { Task { await send() } }
        }
        .confirmationDialog("Afvis mailen? Intet sendes, og opgaven lukkes.", isPresented: $confirmReject, titleVisibility: .visible) {
            Button("Afvis", role: .destructive) { Task { busy = true; if await m.act("api/svarvagt/\(id)/afvis", [:], ok: "Afvist") { dismiss() }; busy = false } }
        }
    }

    /// As on the web: editing stops a pending autosvar first, so it cannot go out mid-edit.
    private func startEdit() async {
        draft = mail["udkast"].text; editing = true
        if mail["autosvar"]["ok"].bool && !mail["auto_stop"].bool {
            _ = try? await API.shared.send("api/svarvagt/\(id)/stop-auto", ["stop": true])
        }
    }

    private func send() async {
        busy = true
        var b: [String: Any] = ["bekraeft": true]
        if editing { b["tekst"] = draft }
        if await m.act("api/svarvagt/\(id)/send", b, ok: "Sendt") { dismiss() }
        busy = false
    }
}
