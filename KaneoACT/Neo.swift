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

    private let suggestions = ["Hvad venter på mig i dag?", "Hvilke frister har jeg denne uge?", "Hvordan går det med agenterne?", "Opsummér de nye mails"]

    /// "@kan" at the end: the open decisions to answer, as the web composer offers them.
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
                    LazyVStack(alignment: .leading, spacing: Theme.s3) {
                        if m.msgs.isEmpty { empty }
                        ForEach(m.msgs) { msg in Bubble(msg: msg).id(msg.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: m.msgs) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .screen()
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Neo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { Task { await m.open(nil) } } label: { Label("Ny samtale", systemImage: "square.and.pencil") }
                        if !m.threads.isEmpty {
                            Section("Samtaler") {
                                ForEach(m.threads, id: \.self) { t in
                                    Button(clean(String(t["titel"].text.prefix(60)))) { Task { await m.open(t["traad"].string) } }
                                }
                            }
                        }
                    } label: { Image(systemName: "clock") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Tilstand", selection: $m.mode) {
                            Text("Hurtig").tag("hurtig"); Text("Normal").tag("normal"); Text("Grundig").tag("grundig")
                            Text("Reserve").tag("reserve"); Text("Lokal").tag("lokal")
                        }
                    } label: { Text(m.mode.capitalized).font(Theme.sans(14, .medium)) }
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

    private var empty: some View {
        VStack(spacing: Theme.s3) {
            KTile(size: 56).padding(.top, 56)
            VStack(spacing: 4) {
                Text("Hvad skal jeg gøre for dig?").font(Theme.sans(20, .semibold)).foregroundStyle(Theme.ink)
                Text("Spørg om opgaver, agenter, mails og Kaneos hjerne. Skriv @ for at svare på en beslutning.")
                    .font(Theme.small).foregroundStyle(Theme.sec).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            VStack(spacing: Theme.s1) {
                ForEach(suggestions, id: \.self) { s in
                    Button { Haptic.tap(); Task { await m.send(s) } } label: {
                        HStack { Text(s).font(Theme.sans(14, .medium)).foregroundStyle(Theme.ink); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.dim) }
                            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
                    }
                    .buttonStyle(Press())
                }
            }
            .padding(.top, Theme.s2)
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: Theme.s1) {
            if !atList.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Svar på en beslutning").font(Theme.tag).foregroundStyle(Theme.dim).padding(.horizontal, Theme.s3).padding(.top, Theme.s2).padding(.bottom, 4)
                    ForEach(atList, id: \.self) { c in
                        Button { pick(c) } label: {
                            HStack(spacing: Theme.s1) {
                                BrandIcon(item: c, size: 24)
                                Text(kode(c)).font(Theme.code).foregroundStyle(Theme.dim)
                                Text(clean(c["navn"].text)).font(Theme.small).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s1).contentShape(Rectangle())
                        }
                        .buttonStyle(Press())
                    }
                }
                .padding(.bottom, Theme.s1)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
            }
            if !m.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.s1) {
                        ForEach(m.files) { f in
                            HStack(spacing: 6) {
                                if let img = f.image { Image(uiImage: img).resizable().scaledToFill().frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6)) }
                                else { Image(systemName: "doc").foregroundStyle(Theme.sec) }
                                Text(f.navn).font(Theme.meta).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 120)
                                if f.uploading { ProgressView().controlSize(.mini) }
                                if f.fejl != nil { Dot(tone: .bad) }
                                Button { m.files.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.raised, in: Capsule())
                        }
                    }
                }
            }
            if dict.listening {
                HStack(spacing: Theme.s1) {
                    Dot(tone: .bad)
                    Text(dict.text.isEmpty ? "Lytter" : dict.text).font(Theme.small).foregroundStyle(Theme.sec).lineLimit(2)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: Theme.s1) {
                Menu {
                    Button { showPhotos = true } label: { Label("Billede", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("Fil", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40).background(Theme.raised, in: Circle())
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Skriv til Neo", text: $text, axis: .vertical)
                        .font(Theme.body).lineLimit(1...6).focused($focused)
                        .padding(.leading, Theme.s3).padding(.vertical, 10)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && m.files.isEmpty {
                        Button { Task { await toggleDictation() } } label: {
                            Image(systemName: dict.listening ? "stop.fill" : "mic").font(.system(size: 16, weight: .medium))
                                .foregroundStyle(dict.listening ? Theme.bad : Theme.sec).frame(width: 36, height: 40)
                        }
                    } else {
                        Button {
                            let t = text; text = ""; Haptic.tap()
                            Task { await m.send(t) }
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent)
                                .frame(width: 32, height: 32).background(m.busy ? Theme.dim : Theme.accent, in: Circle())
                        }
                        .disabled(m.busy).padding(4)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(focused ? Theme.lineStrong : Theme.line))
            }
            if dict.denied { Text("Giv adgang til mikrofon og talegenkendelse i Indstillinger.").font(Theme.meta).foregroundStyle(Theme.bad) }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s1)
        .background(.bar)
    }

    private func pick(_ c: JSON) {
        if let r = text.range(of: "@[^\\s@]*$", options: .regularExpression) { text.replaceSubrange(r, with: "@\(kode(c)) ") }
        Haptic.tap(); focused = true
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
        if mine {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(Array(msg.filer.enumerated()), id: \.offset) { _, f in
                        Label(f["navn"].text, systemImage: f["billede"].bool ? "photo" : "doc").font(Theme.meta).foregroundStyle(Theme.onAccent.opacity(0.8))
                    }
                    Text(msg.tekst).font(Theme.body).foregroundStyle(Theme.onAccent).textSelection(.enabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: Theme.s1) {
                if msg.live && (msg.tekst.isEmpty || !msg.arb.isEmpty) { Orb(size: 20) } else { KTile(size: 24).padding(.top, 2) }
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(Array(msg.vis.enumerated()), id: \.offset) { _, v in ActionChip(v: v) }
                    if !msg.tekst.isEmpty {
                        Text(markdown(clean(msg.tekst))).font(Theme.body).foregroundStyle(Theme.ink).lineSpacing(4).textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
                    }
                    if msg.live && (msg.tekst.isEmpty || !msg.arb.isEmpty) {
                        Text(msg.arb.isEmpty ? "Neo tænker" : msg.arb).font(Theme.small).foregroundStyle(Theme.sec).padding(.top, 2)
                    }
                    if !msg.kilder.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(msg.kilder.enumerated()), id: \.offset) { _, k in
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text").font(.system(size: 10))
                                        Text(clean(k["titel"].string ?? k["overskrift"].string ?? k["fil"].text)).font(Theme.tag).lineLimit(1)
                                    }
                                    .foregroundStyle(Theme.sec)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.raised, in: Capsule())
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 24)
            }
        }
    }
}

/// One of Neo's actions ({vis}): a task created, a decision answered, an error.
struct ActionChip: View {
    let v: JSON
    var body: some View {
        let type = v["type"].text
        let title = [kode(v), clean(v["navn"].text)].filter { !$0.isEmpty }.joined(separator: " ")
        HStack(spacing: Theme.s1) {
            Dot(tone: type == "fejl" ? .bad : .ok)
            VStack(alignment: .leading, spacing: 1) {
                Text(type.capitalizedFirst).font(Theme.tag).foregroundStyle(Theme.dim)
                Text(title.isEmpty ? clean(v["tekst"].text) : title).font(Theme.small).foregroundStyle(Theme.ink).lineLimit(2)
            }
        }
        .padding(.horizontal, Theme.s2).padding(.vertical, Theme.s1)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
