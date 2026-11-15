import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Quick actions on "Til dig": two rows of four, scroll sideways for more. Each opens its sheet
// directly (no pages in between) on ACT's existing API. Long press and drag to reorder; the order
// is remembered on the phone. The same actions back the home-screen shortcuts.
enum QuickAction: String, CaseIterable, Identifiable {
    case neo, opgave, scan, bogfoer, faktura, kontrakt, mails, dikter, leads, pause
    var id: String { rawValue }
    var title: String {
        switch self {
        case .neo: return "Spørg Neo"
        case .opgave: return "Ny opgave"
        case .scan: return "Scan kvittering"
        case .bogfoer: return "Bogfør fakturaer"
        case .faktura: return "Ny faktura"
        case .kontrakt: return "Ny kontrakt"
        case .mails: return "Svar på mails"
        case .dikter: return "Diktér note"
        case .leads: return "Find leads"
        case .pause: return "Pause alle"
        }
    }
    var icon: String {
        switch self {
        case .neo: return "waveform"
        case .opgave: return "plus.circle"
        case .scan: return "camera.viewfinder"
        case .bogfoer: return "tray.and.arrow.down"
        case .faktura: return "doc.text"
        case .kontrakt: return "signature"
        case .mails: return "envelope"
        case .dikter: return "mic"
        case .leads: return "person.badge.plus"
        case .pause: return "pause.circle"
        }
    }
}

enum QuickSheet: String, Identifiable { case opgave, scan, faktura, kontrakt, dikter; var id: String { rawValue } }
enum QuickAsk: String, Identifiable { case leads, pause; var id: String { rawValue } }

/// Runs a quick action: a tab switch, Neo with a starting text, or a sheet on "Til dig".
@MainActor enum Quick {
    static func run(_ a: QuickAction) {
        Haptic.tap()
        let r = Router.shared
        switch a {
        case .neo: r.askNeo(nil)
        case .bogfoer: r.askNeo("Find og bogfør fakturaer fra ")
        case .mails: r.tab = .mail
        case .opgave: r.tab = .idag; r.sheet = .opgave
        case .scan: r.tab = .idag; r.sheet = .scan
        case .faktura: r.tab = .idag; r.sheet = .faktura
        case .kontrakt: r.tab = .idag; r.sheet = .kontrakt
        case .dikter: r.tab = .idag; r.sheet = .dikter
        case .leads: r.tab = .idag; r.ask = .leads
        case .pause: r.tab = .idag; r.ask = .pause
        }
    }
    /// Home-screen shortcuts (long press on the app icon).
    static func shortcut(_ type: String) {
        switch type {
        case "neo": run(.neo)
        case "scan": run(.scan)
        case "opgave": run(.opgave)
        default: Router.shared.tab = .idag
        }
    }
}

struct QuickGrid: View {
    @AppStorage("quick.order") private var stored = ""
    @ObservedObject private var store = Store.shared

    private var order: [QuickAction] {
        var o = stored.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }
        for a in QuickAction.allCases where !o.contains(a) { o.append(a) }
        return o
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(86), spacing: Theme.s2), GridItem(.fixed(86), spacing: Theme.s2)], spacing: Theme.s1) {
                ForEach(order) { a in
                    Button { Quick.run(a) } label: { tile(a) }
                        .buttonStyle(Press())
                        .containerRelativeFrame(.horizontal, count: 4, spacing: Theme.s1)
                        .draggable(a.rawValue) { tile(a).frame(width: 80) }
                        .dropDestination(for: String.self) { items, _ in
                            guard let src = items.first.flatMap(QuickAction.init(rawValue:)), src != a else { return false }
                            var o = order
                            o.removeAll { $0 == src }
                            o.insert(src, at: o.firstIndex(of: a) ?? o.count)
                            withAnimation(.easeOut(duration: 0.2)) { stored = o.map(\.rawValue).joined(separator: ",") }
                            Haptic.tap()
                            return true
                        }
                        .accessibilityLabel(label(a))
                        .accessibilityHint("Hold og træk for at flytte")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: 86 * 2 + Theme.s2)
    }

    private func label(_ a: QuickAction) -> String {
        a == .pause && store.overblik["pause"]["pause"].bool ? "Genoptag alle" : a.title
    }

    private func tile(_ a: QuickAction) -> some View {
        VStack(spacing: 6) {
            Image(systemName: a == .pause && store.overblik["pause"]["pause"].bool ? "play.circle" : a.icon)
                .font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Theme.line))
            Text(label(a)).font(Theme.sans(11, .medium)).foregroundStyle(Theme.sec)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .top)
        .contentShape(Rectangle())
    }
}

// MARK: - Sheets
struct NewTaskSheet: View {
    var initial = ""
    @State private var navn = ""
    @State private var tekst = ""
    @State private var harFrist = false
    @State private var frist = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var ansvarlig = "Marco"
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @ObservedObject private var agents = Store.agentNames
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hvad skal gøres", text: $navn, axis: .vertical).font(Theme.body).focused($focused)
                    TextField("Detaljer (valgfrit)", text: $tekst, axis: .vertical).font(Theme.small).lineLimit(3...8)
                }
                Section {
                    Picker("Ansvarlig", selection: $ansvarlig) {
                        ForEach(agents.names, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Frist", isOn: $harFrist.animation()).tint(Theme.ok)
                    if harFrist { DatePicker("Dato", selection: $frist, displayedComponents: .date).environment(\.locale, Locale(identifier: "da_DK")) }
                }
                if let error { Section { Text(error).foregroundStyle(Theme.bad).font(Theme.small) } }
            }
            .font(Theme.body)
            .navigationTitle("Ny opgave").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Opret") { Task { await save() } }.font(Theme.button)
                        .disabled(busy || navn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if navn.isEmpty { navn = initial }; focused = true }
            .task { await agents.load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        busy = true; error = nil
        var b: [String: Any] = ["navn": navn.trimmingCharacters(in: .whitespacesAndNewlines), "tekst": tekst, "ansvarlig": ansvarlig, "gruppe": "unstarted"]
        if harFrist {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            b["frist"] = f.string(from: frist)
        }
        do {
            try await API.shared.send("api/opgave", b)
            Haptic.approve(); Toast.shared.show("Opgaven er oprettet")
            dismiss(); await Store.shared.load()
        } catch { Haptic.fail(); self.error = error.localizedDescription }
        busy = false
    }
}

/// The names a task can be given to: Marco and the agents, as on the web.
@MainActor final class AgentNames: ObservableObject {
    @Published var names = ["Marco"]
    private var loaded = false
    func load() async {
        guard !loaded, let d = try? await API.shared.get("api/mit") else { return }
        let n = d["ansvarlige"].array.compactMap { $0.string }
        if !n.isEmpty { names = n; loaded = true }
    }
}
extension Store { static let agentNames = AgentNames() }

/// Speak a note; it becomes a task for Marco.
struct DictateNoteSheet: View {
    @StateObject private var dict = Dictation()
    @State private var text = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.s3) {
                if dict.listening {
                    HStack(spacing: Theme.s1) { Dot(tone: .bad); Text("Lytter").font(Theme.small).foregroundStyle(Theme.sec) }
                    Text(dict.text.isEmpty ? "Sig det, du vil huske." : dict.text).font(Theme.sans(19)).foregroundStyle(dict.text.isEmpty ? Theme.dim : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextEditor(text: $text).font(Theme.sans(17)).scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty { Text("Tryk på mikrofonen og tal.").font(Theme.sans(17)).foregroundStyle(Theme.dim).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                        }
                }
                Spacer()
                HStack {
                    Spacer()
                    Button { Task { await toggle() } } label: {
                        Image(systemName: dict.listening ? "stop.fill" : "mic.fill").font(.system(size: 26))
                            .foregroundStyle(dict.listening ? Color.white : Theme.onAccent)
                            .frame(width: 72, height: 72)
                            .background(dict.listening ? Theme.badSolid : Theme.accent, in: Circle())
                    }
                    .accessibilityLabel(dict.listening ? "Stop" : "Diktér")
                    Spacer()
                }
                if dict.denied { Text("Giv adgang til mikrofon og talegenkendelse i Indstillinger.").font(Theme.meta).foregroundStyle(Theme.bad) }
            }
            .padding(Theme.s3)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Diktér note").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { _ = dict.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem som opgave") { Task { await save() } }.font(Theme.button)
                        .disabled(busy || dict.listening || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { await dict.start() }
        }
    }

    private func toggle() async {
        if dict.listening {
            let heard = dict.stop()
            if !heard.isEmpty { text = text.isEmpty ? heard : text + " " + heard }
        } else { await dict.start() }
    }

    private func save() async {
        busy = true
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = t.split(separator: "\n").first.map(String.init) ?? t
        let navn = first.count > 80 ? String(first.prefix(77)) + "..." : first
        do {
            try await API.shared.send("api/opgave", ["navn": navn, "tekst": t, "ansvarlig": "Marco", "gruppe": "unstarted"])
            Haptic.approve(); Toast.shared.show("Noten er gemt som opgave"); dismiss()
            await Store.shared.load()
        } catch { Haptic.fail(); Toast.shared.show(error.localizedDescription) }
        busy = false
    }
}

/// Camera straight to Bilag: the photo goes to POST /api/bilag/upload and is read like any upload.
struct ScanReceipt: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ScanReceipt
        init(_ p: ScanReceipt) { parent = p }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let img = info[.originalImage] as? UIImage
            parent.dismiss()
            guard let img else { return }
            Task { @MainActor in await ScanReceipt.upload(img) }
        }
    }

    @MainActor static func upload(_ img: UIImage) async {
        // Keep it well under the server's 10 MB: scale the long side to 2400 px.
        let maxSide: CGFloat = 2400
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = scaled.jpegData(compressionQuality: 0.8) else { return }
        Toast.shared.show("Kvitteringen sendes til Bilag")
        do {
            let name = "kvittering-\(Int(Date().timeIntervalSince1970)).jpg"
            try await API.shared.send("api/bilag/upload", ["navn": name, "data": jpg.base64EncodedString()])
            Haptic.approve(); Toast.shared.show("Kvitteringen er i Bilag og læses nu")
            await Store.shared.load()
        } catch { Haptic.fail(); Toast.shared.show("Kvitteringen blev ikke sendt. \(error.localizedDescription)") }
    }
}

/// A new invoice draft in ACT (nothing is sent; it is checked and sent from ACT).
struct NewInvoiceSheet: View {
    @State private var navn = ""
    @State private var cvr = ""
    @State private var email = ""
    @State private var tekst = ""
    @State private var antal = 1
    @State private var pris = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Firmanavn", text: $navn)
                    TextField("CVR", text: $cvr).keyboardType(.numberPad)
                    TextField("Mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Linje") {
                    TextField("Hvad faktureres", text: $tekst)
                    Stepper("Antal: \(antal)", value: $antal, in: 1...999)
                    TextField("Pris pr. stk. i kr. ekskl. moms", text: $pris).keyboardType(.decimalPad)
                }
                Section { Text("Fakturaen gemmes som kladde i ACT. Den tjekkes og sendes derfra.").font(Theme.meta).foregroundStyle(Theme.dim) }
                if let error { Section { Text(error).foregroundStyle(Theme.bad).font(Theme.small) } }
            }
            .font(Theme.body)
            .navigationTitle("Ny faktura").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem kladde") { Task { await save() } }.font(Theme.button)
                        .disabled(busy || navn.isEmpty || tekst.isEmpty || Double(pris.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
        }
    }

    private func save() async {
        busy = true; error = nil
        let p = Double(pris.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")) ?? Double(pris) ?? 0
        let b: [String: Any] = ["kunde": ["navn": navn, "cvr": cvr, "email": email],
                                "linjer": [["produkt": "fri", "tekst": tekst, "antal": antal, "pris_oere": Int((p * 100).rounded())]]]
        do {
            let r = try await API.shared.send("api/fakturaer", b)
            Haptic.approve(); Toast.shared.show("Fakturakladde \(r["nr"].string.map { "F" + $0 } ?? "") er gemt"); dismiss()
        } catch { Haptic.fail(); self.error = error.localizedDescription }
        busy = false
    }
}

/// A new contract draft in ACT. The price always comes from Kaneo's catalogue (server side).
struct NewContractSheet: View {
    @State private var firmanavn = ""
    @State private var cvr = ""
    @State private var kontakt = ""
    @State private var email = ""
    @State private var skabelon = "noa-linje-abonnement"
    @State private var niveau = ""
    @State private var niveauer: [(String, String)] = []
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private let skabeloner = [("noa-linje-abonnement", "Abonnement"), ("abonnement-binding", "Abonnement med binding"),
                              ("proeve-noa-linje", "Prøveperiode"), ("databehandleraftale", "Databehandleraftale")]

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Firmanavn", text: $firmanavn)
                    TextField("CVR", text: $cvr).keyboardType(.numberPad)
                    TextField("Kontaktperson", text: $kontakt)
                    TextField("Mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Aftale") {
                    Picker("Skabelon", selection: $skabelon) { ForEach(skabeloner, id: \.0) { Text($0.1).tag($0.0) } }
                    if skabelon != "databehandleraftale" && !niveauer.isEmpty {
                        Picker("Plan", selection: $niveau) { ForEach(niveauer, id: \.0) { Text($0.1).tag($0.0) } }
                    }
                }
                Section { Text("Kontrakten gemmes som kladde i ACT. Prisen kommer fra Kaneos prisliste, og den tjekkes og sendes derfra.").font(Theme.meta).foregroundStyle(Theme.dim) }
                if let error { Section { Text(error).foregroundStyle(Theme.bad).font(Theme.small) } }
            }
            .font(Theme.body)
            .navigationTitle("Ny kontrakt").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem kladde") { Task { await save() } }.font(Theme.button).disabled(busy || firmanavn.isEmpty)
                }
            }
            .task {
                guard let d = try? await API.shared.get("api/fakturaer") else { return }
                let v = d["katalog"]["kaneo_voice"].object
                niveauer = v.keys.sorted().map { ($0, v[$0]?["navn"].string ?? $0) }
                if niveau.isEmpty { niveau = niveauer.first?.0 ?? "" }
            }
        }
    }

    private func save() async {
        busy = true; error = nil
        var b: [String: Any] = ["skabelon": skabelon,
                                "modpart": ["firmanavn": firmanavn, "cvr": cvr, "kontaktperson": kontakt, "email": email]]
        if skabelon != "databehandleraftale" { b["plan"] = ["produkt": "kaneo_voice", "niveau": niveau, "periode": "monthly"] }
        do {
            let r = try await API.shared.send("api/kontrakter", b)
            Haptic.approve(); Toast.shared.show("Kontraktkladde \(r["nr"].string.map { "K" + $0 } ?? "") er gemt"); dismiss()
        } catch { Haptic.fail(); self.error = error.localizedDescription }
        busy = false
    }
}

// MARK: - Home-screen shortcuts
final class ShortcutSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor item: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let t = item.type
        Task { @MainActor in Quick.shortcut(t) }
        completionHandler(true)
    }
}
