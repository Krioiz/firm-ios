import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Speech
import AVFoundation

// Neo: the same chat as ACT's Neo page. POST /api/chat answers as NDJSON (one object per line):
// {traad} first, then {arbejder} while a tool runs, {d} text deltas, {vis} action cards,
// {erstat} a corrected full answer, {kilder} brain sources, {vagt} the action guard's verdict.
struct ChatMsg: Identifiable, Equatable {
    let id = UUID()
    var rolle: String
    var tekst: String
    var vis: [JSON] = []
    var kilder: [JSON] = []
    var filer: [JSON] = []
    var arb: String = ""
    var live = false
}

struct Attachment: Identifiable {
    let id = UUID()
    var navn: String
    var image: UIImage?
    var serverId: String?
    var uploading = true
    var fejl: String?
}

let workingText: [String: String] = [
    "besvar_beslutning": "Gemmer dit svar…", "handlingsvagt": "Tjekker at handlingerne er udført…", "sog_opgaver": "Søger i opgaver…",
    "hent_opgave": "Læser opgaven…", "opret_opgave": "Opretter opgave…", "ret_opgave": "Retter opgaven…", "slet_opgave": "Sletter…",
    "gendan_opgave": "Gendanner…", "kommenter": "Skriver kommentar…", "agent_status": "Tjekker agenterne…", "giv_agent_opgave": "Giver opgaven videre…",
    "sog_hjerne": "Søger i Kaneos hjerne…", "lokal": "Den lokale model tænker…",
]

@MainActor final class NeoModel: ObservableObject {
    @Published var msgs: [ChatMsg] = []
    @Published var traad: String? = UserDefaults.standard.string(forKey: "neo.traad")
    @Published var threads: [JSON] = []
    @Published var busy = false
    @Published var files: [Attachment] = []
    @Published var mode = UserDefaults.standard.string(forKey: "neo.mode") ?? "normal"

    func loadThreads() async { threads = (try? await API.shared.get("api/chat"))?.array ?? [] }

    func open(_ t: String?) async {
        traad = t; UserDefaults.standard.set(t, forKey: "neo.traad")
        guard let t else { msgs = []; return }
        let rows = (try? await API.shared.get("api/chat/\(t)"))?.array ?? []
        msgs = rows.map { ChatMsg(rolle: $0["rolle"].text, tekst: $0["tekst"].text, vis: $0["vis"].array, kilder: $0["kilder"].array, filer: $0["filer"].array) }
    }

    func attach(_ data: Data, name: String, mime: String, image: UIImage?) {
        guard data.count <= 25 * 1024 * 1024 else { Toast.shared.show("\(name) er over 25 MB"); return }
        let a = Attachment(navn: name, image: image)
        files.append(a)
        Task {
            do {
                let r = try await API.shared.uploadChatFile(data, name: name, mime: mime)
                update(a.id) { $0.serverId = r["id"].string; $0.navn = r["navn"].string ?? name; $0.uploading = false }
            } catch { update(a.id) { $0.uploading = false; $0.fejl = error.localizedDescription } }
        }
    }
    private func update(_ id: UUID, _ f: (inout Attachment) -> Void) {
        if let i = files.firstIndex(where: { $0.id == id }) { f(&files[i]) }
    }

    func send(_ text: String) async {
        if files.contains(where: { $0.uploading }) { Toast.shared.show("Venter på upload…"); return }
        let ids = files.compactMap { $0.serverId }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !(t.isEmpty && ids.isEmpty) else { return }
        if t.isEmpty { t = "Se den vedhæftede fil." }
        busy = true
        msgs.append(ChatMsg(rolle: "user", tekst: t, filer: files.filter { $0.serverId != nil }.map { .obj(["navn": .str($0.navn)]) }))
        files = []
        let reply = ChatMsg(rolle: "assistant", tekst: "", live: true)
        msgs.append(reply)
        // Looked up by id each time: switching thread mid-answer replaces msgs.
        func edit(_ f: (inout ChatMsg) -> Void) { if let i = msgs.firstIndex(where: { $0.id == reply.id }) { f(&msgs[i]) } }
        var body: [String: Any] = ["tekst": t, "tilstand": mode, "filer": ids]
        if let traad { body["traad"] = traad }
        var changed = false
        do {
            for try await o in API.shared.stream("api/chat", body) {
                if let tr = o["traad"].string { traad = tr; UserDefaults.standard.set(tr, forKey: "neo.traad") }
                if let a = o["arbejder"].string { edit { $0.arb = workingText[a] ?? "Arbejder…" } }
                if !o["vis"].isNull { edit { $0.vis.append(o["vis"]); $0.arb = "" }; changed = true }
                if !o["kilder"].isNull { edit { $0.kilder = o["kilder"].array } }
                if let e = o["erstat"].string { edit { $0.tekst = e } }
                if let d = o["d"].string { edit { $0.tekst += d; $0.arb = "" } }
            }
        } catch {
            edit { $0.tekst += "\n\n(Neo kunne ikke svare. Prøv igen.)" }
        }
        edit { $0.live = false; $0.arb = "" }
        busy = false
        if changed { Router.shared.changed() }
        await loadThreads()
    }
}

struct NeoView: View {
    @StateObject private var m = NeoModel()
    @StateObject private var dict = Dictation()
    @ObservedObject private var store = Store.shared
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @FocusState private var focused: Bool

    /// "@kan" at the cursor's word: the open decisions to answer, as the web composer offers them.
    private var atQuery: String? {
        guard let r = text.range(of: "(^|\\s)@([^\\s@]*)$", options: .regularExpression) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces).dropFirst().lowercased()
    }
    private var atList: [JSON] {
        guard let q = atQuery else { return [] }
        return store.decisions.filter { q.isEmpty || (kode($0) + " " + $0["navn"].text).lowercased().contains(q) }.prefix(6).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if m.msgs.isEmpty {
                            VStack(spacing: 10) {
                                Image("Logo").resizable().frame(width: 56, height: 56)
                                Text("Spørg Neo om opgaver, agenter, mails og Kaneos hjerne. Skriv @ for at svare på en beslutning.")
                                    .font(Theme.font(.footnote)).foregroundStyle(Theme.sec).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        ForEach(m.msgs) { msg in Bubble(msg: msg).id(msg.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: m.msgs) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Neo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { Task { await m.open(nil) } } label: { Label("Ny samtale", systemImage: "square.and.pencil") }
                        if !m.threads.isEmpty {
                            Section("Samtaler") {
                                ForEach(m.threads, id: \.self) { t in
                                    Button(String(t["titel"].text.prefix(60))) { Task { await m.open(t["traad"].string) } }
                                }
                            }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Tilstand", selection: $m.mode) {
                            Text("Hurtig").tag("hurtig"); Text("Normal").tag("normal"); Text("Grundig").tag("grundig")
                            Text("Reserve").tag("reserve"); Text("Lokal").tag("lokal")
                        }
                    } label: { Label(m.mode.capitalized, systemImage: "dial.medium") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await m.open(nil) } } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .task { await m.loadThreads(); if m.msgs.isEmpty, let t = m.traad { await m.open(t) } }
            .onChange(of: m.mode) { _, v in UserDefaults.standard.set(v, forKey: "neo.mode") }
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        let jpg = img.jpegData(compressionQuality: 0.85) ?? d
                        m.attach(jpg, name: "billede-\(Int(Date().timeIntervalSince1970)).jpg", mime: "image/jpeg", image: img)
                    }
                    photo = nil
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                for u in urls.prefix(10) {
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: u) {
                        let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        m.attach(d, name: u.lastPathComponent, mime: mime, image: mime.hasPrefix("image/") ? UIImage(data: d) : nil)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !atList.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Svar på en beslutning").font(Theme.font(.caption, .semibold)).foregroundStyle(Theme.dim).padding(.bottom, 4)
                    ForEach(atList, id: \.self) { c in
                        Button { pick(c) } label: {
                            HStack(spacing: 8) {
                                BrandIcon(item: c, size: 22)
                                Text(kode(c)).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.dim)
                                Text(c["navn"].text).font(Theme.font(.footnote)).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card()
            }
            if !m.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(m.files) { f in
                            HStack(spacing: 6) {
                                if let img = f.image { Image(uiImage: img).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6)) }
                                else { Image(systemName: "doc").foregroundStyle(Theme.sec) }
                                Text(f.navn).font(Theme.font(.caption)).lineLimit(1).frame(maxWidth: 120)
                                if f.uploading { ProgressView().controlSize(.mini) }
                                if f.fejl != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad) }
                                Button { m.files.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim) }
                            }
                            .padding(6).background(Theme.card, in: Capsule())
                        }
                    }
                }
            }
            if dict.listening {
                Text(dict.text.isEmpty ? "Lytter…" : dict.text).font(Theme.font(.footnote)).foregroundStyle(Theme.sec).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label("Billede", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("Fil", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 36)
                }
                TextField("Skriv til Neo…", text: $text, axis: .vertical)
                    .lineLimit(1...6).focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && m.files.isEmpty {
                    Button { Task { await toggleDictation() } } label: {
                        Image(systemName: dict.listening ? "stop.circle.fill" : "mic.fill").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(dict.listening ? Theme.bad : Theme.accent).frame(width: 36, height: 36)
                    }
                } else {
                    Button {
                        let t = text; text = ""
                        Task { await m.send(t) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(m.busy ? Theme.dim : Theme.accent)
                    }
                    .disabled(m.busy)
                }
            }
            if dict.denied { Text("Giv adgang til mikrofon og talegenkendelse i Indstillinger.").font(Theme.font(.caption2)).foregroundStyle(Theme.bad) }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func pick(_ c: JSON) {
        if let r = text.range(of: "@[^\\s@]*$", options: .regularExpression) { text.replaceSubrange(r, with: "@\(kode(c)) ") }
        focused = true
    }

    private func toggleDictation() async {
        if dict.listening {
            let heard = dict.stop()
            if !heard.isEmpty { text = text.isEmpty ? heard : text + " " + heard }
        } else {
            await dict.start()
        }
    }
}

struct Bubble: View {
    let msg: ChatMsg
    var body: some View {
        let mine = msg.rolle == "user"
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if !msg.filer.isEmpty {
                    ForEach(Array(msg.filer.enumerated()), id: \.offset) { _, f in
                        Label(f["navn"].text, systemImage: f["billede"].bool ? "photo" : "doc").font(Theme.font(.caption)).foregroundStyle(mine ? Color.white.opacity(0.85) : Theme.sec)
                    }
                }
                ForEach(Array(msg.vis.enumerated()), id: \.offset) { _, v in ActionChip(v: v) }
                if !msg.tekst.isEmpty {
                    Text(markdown(msg.tekst)).font(Theme.font(.body)).foregroundStyle(mine ? Color.white : Theme.ink).textSelection(.enabled)
                }
                if !msg.arb.isEmpty || (msg.live && msg.tekst.isEmpty) {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(msg.arb.isEmpty ? "Neo tænker…" : msg.arb).font(Theme.font(.caption)).foregroundStyle(Theme.sec) }
                }
                if !msg.kilder.isEmpty {
                    Text("Kilder: " + msg.kilder.map { $0["titel"].string ?? $0["fil"].text }.joined(separator: " · ")).font(Theme.font(.caption2)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(mine ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.card), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 20) }
        }
    }
}

/// One of Neo's actions ({vis}): a task created, a decision answered, an error.
struct ActionChip: View {
    let v: JSON
    var body: some View {
        let type = v["type"].text
        let title = [kode(v), v["navn"].text].filter { !$0.isEmpty }.joined(separator: " ")
        HStack(spacing: 6) {
            Image(systemName: type == "fejl" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(type == "fejl" ? Theme.bad : Theme.ok)
            VStack(alignment: .leading, spacing: 1) {
                Text(type.capitalized).font(Theme.font(.caption2, .semibold)).foregroundStyle(Theme.dim)
                Text(title.isEmpty ? v["tekst"].text : title).font(Theme.font(.caption)).foregroundStyle(Theme.ink).lineLimit(2)
            }
        }
        .padding(8).background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
    }
}

// Tap to talk. Apple's recogniser, Danish, on-device when iOS has the Danish model, so the audio
// stays on the phone; only the text goes to Neo, exactly as if typed.
@MainActor final class Dictation: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var denied = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "da-DK"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        let mic = await AVAudioApplication.requestRecordPermission()
        denied = !(speech == .authorized && mic)
        return !denied
    }

    func start() async {
        guard !listening else { return }
        guard await authorize(), let recognizer, recognizer.isAvailable else { denied = true; return }
        text = ""
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { denied = true; return }
        listening = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let r = result { self.text = r.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self.teardown() }
            }
        }
    }

    @discardableResult
    func stop() -> String {
        if listening { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        request?.endAudio()
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        return heard
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
