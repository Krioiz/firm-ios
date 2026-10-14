import UIKit
import Foundation
import Speech
import AVFoundation

// Hold to talk. Apple's own recogniser (the keyboard's dictation engine), Danish, live text
// while you speak. Nothing leaves the phone except what Apple's dictation already sends; the
// text goes to the server exactly as if typed. On-device when iOS offers it for Danish.
@MainActor final class Dictation: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var level: CGFloat = 0          // 0...1, for the waveform
    @Published var history: [CGFloat] = Array(repeating: 0, count: 44)   // the last few seconds, newest last
    @Published var denied = false
    private(set) var startedAt = Date()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "da-DK"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var available: Bool { recognizer?.isAvailable ?? false }

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        let mic = await AVAudioApplication.requestRecordPermission()
        let ok = speech == .authorized && mic
        denied = !ok
        return ok
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
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }   // prefer accuracy; on-device is the fallback Apple picks itself
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            // a rough loudness for the waveform
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength); var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            let lv = CGFloat(min(1, rms * 12))
            Task { @MainActor in
                guard let self else { return }
                self.level = lv
                self.history.removeFirst(); self.history.append(lv)
            }
        }
        engine.prepare()
        do { try engine.start() } catch { denied = true; return }
        listening = true; startedAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let r = result { self.text = r.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self.teardown() }
            }
        }
    }

    /// Returns what was heard.
    @discardableResult
    func stop() -> String {
        if listening { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        request?.endAudio()
        teardown()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        listening = false; level = 0; history = Array(repeating: 0, count: 44)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
