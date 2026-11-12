// The one state of the iPhone app: idle, recording or transcribing. The screen, the Shortcuts actions (Action Button,
// Control Centre, Lock Screen) and the Live Activity all read and change this one object, so they can never disagree.
// That is the cure for the probe's three bugs (stt-iphone.md, «Measured»): a label set after the fact, a second Live
// Activity over the first, a recording started by an action the screen never heard of.
// - Stop ends the microphone and the Live Activity first, then transcribes; a press while a text is being made does
//   nothing.
// - The recording is written to a file as it goes (AAC in CAF, which stays readable if the app is killed mid-way) and
//   kept in memory for the engine. The last recording stays until the next one, for Send; nothing else is kept.
// - A call, Siri or an alarm ends the recording as a Stop would: what was said is transcribed.
// - The model stays loaded; iOS may drop the app under memory pressure, and the next dictation loads it again (~1 s).
import ActivityKit
import WidgetKit
import AVFoundation
import Observation
import UIKit

// Models on the iPhone: Whisper and Parakeet, on every iPhone with iOS 26; Qwen stays on the Mac (his word 2026-11-11).
let phoneModels = models.filter { $0.id != "Qwen3-ASR-1.7B" }

@MainActor @Observable final class Dictation: RecordingHost {
    static let shared = Dictation()

    enum Phase: Equatable { case idle, recording, transcribing }
    var phase: Phase = .idle {
        didSet {
            // The Record control follows the one state: mic at rest, stop while recording.
            if (phase == .recording) != Shared.recording {
                Shared.recording = phase == .recording
                ControlCenter.shared.reloadControls(ofKind: Shared.controlKind)
            }
        }
    }
    var text = ""                        // the last text, on screen and editable
    var started = Date()
    var levels: [Float] = Array(repeating: 0, count: 11)   // the voice now, 0...1, newest last
    var history: [Float] = []            // loudness of every 50 ms so far, for the running waveform (bin i = i × 50 ms)
    var stopped: Date?                   // when Stop was pressed: the timer and the wave stand still from then
    @ObservationIgnored private var binSum: Float = 0
    @ObservationIgnored private var binCount = 0
    var problem: String?                 // a fact for an alert («No speech found»)
    var audio: URL?         // the last recording, for Send

    // The model: chosen on each device (it doesn't sync, stt.md «Sync»).
    var modelID: String? {
        didSet { UserDefaults.standard.set(modelID, forKey: "model"); loadedID = nil }
    }
    var current: ASRModel? { phoneModels.first { $0.id == modelID && $0.isHere } }
    var downloading: (id: String, share: Double)?
    private var download: Download?

    let engine = Engine()
    private var loadedID: String?
    private var mic: AVAudioEngine?
    private var samples: [Float] = []
    private var file: AVAudioFile?
    private var activity: Activity<RecordingAttributes>?
    private var tail: Task<Void, Never>?

    var isRecording: Bool { phase == .recording }

    // Copy Text: on this device only, on unless the person turns it off (the Mac always copies; some want the text to
    // stay in the app, his word 2026-11-11).
    static var copies: Bool { UserDefaults.standard.object(forKey: "copyText") as? Bool ?? true }

    init() {
        modelID = UserDefaults.standard.string(forKey: "model")
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let began = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began, Dictation.shared.isRecording { trace("interrupted"); Task { await Dictation.shared.stop() } } }
        }
        NotificationCenter.default.addObserver(forName: Store.changedFromCloud, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.passSettings(); History.shared.purge(); Shelf.shared.reload() }
        }
    }

    // MARK: recording

    @discardableResult func start() -> LocalizedStringResource? {
        guard phase == .idle else { return nil }
        guard current != nil else { problem = String(localized: "No model chosen"); return "No model chosen" }
        do {
            let s = AVAudioSession.sharedInstance()
            // Other sound pauses while recording and comes back after, as in Voice Memos; no Bluetooth headset as the
            // microphone, so the headphones keep their sound (the Mac's choice, stt.md).
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try s.setActive(true)
            let e = AVAudioEngine()
            let input = e.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0 else { throw STTError(localizedStringResource: "No microphone is connected.") }
            let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            guard let conv = AVAudioConverter(from: inFormat, to: out) else { throw STTError(localizedStringResource: "Recording failed") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording.caf")
            try? FileManager.default.removeItem(at: url)
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                                                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            samples = []; samples.reserveCapacity(16000 * 120)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buf, _ in
                let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFormat.sampleRate) + 16
                guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
                var fed = false
                conv.convert(to: o, error: nil) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return buf
                }
                try? f.write(from: o)
                let chunk = Array(UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
                let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
                Task { @MainActor in Dictation.shared.take(chunk, level: min(1, rms * 12)) }
            }
            try e.start()
            mic = e; file = f; audio = nil; started = Date(); stopped = nil; history = []; binSum = 0; binCount = 0
            phase = .recording
            UserDefaults.standard.set(true, forKey: "recordingOpen")
            UIApplication.shared.isIdleTimerDisabled = true
            startActivity()
            preload()
            trace("start state=\(UIApplication.shared.applicationState.rawValue) locked=\(!UIApplication.shared.isProtectedDataAvailable)")
            return nil
        } catch {
            trace("start failed \(error)")
            cleanUpMic()
            let text = (error as? STTError)?.localizedStringResource ?? "Recording failed"
            problem = String(localized: text)
            return text
        }
    }

    // Taken while the microphone is open, the 0.3 s tail after Stop included.
    private func take(_ chunk: [Float], level: Float) {
        guard mic != nil else { return }
        samples.append(contentsOf: chunk)
        levels.removeFirst(); levels.append(level)
        for v in chunk {
            binSum += v * v; binCount += 1
            // Loudness in decibels, -55 dB (room) to -5 dB (loud speech) mapped to 0...1: a straight RMS × 12 hit the
            // top on his iPhone's microphone (his 13:25 video, the wave filled the card).
            if binCount == 800 {
                let db = 10 * log10(max(binSum / 800, 1e-10))
                history.append(min(1, max(0, (db + 55) / 50))); binSum = 0; binCount = 0
                if history.count % 5 == 0 { updateActivity() }   // four times a second: the island's wave
            }
        }
    }

    // The Mac keeps 0.3 s more after the stop so the last word isn't cut; the same here.
    @discardableResult func stop() async -> String {
        guard phase == .recording else { return "" }
        stopped = Date()
        phase = .transcribing
        try? await Task.sleep(for: .milliseconds(300))
        let url = file?.url
        cleanUpMic()
        UserDefaults.standard.removeObject(forKey: "recordingOpen")
        await endActivity()
        audio = await shareable(url)
        let pcm = samples; samples = []
        trace("stop \(String(format: "%.1f", Double(pcm.count) / 16000)) s")
        return await finish(pcm)
    }

    // Cancel throws the recording away, as the Mac's Cancel Recording key does: no text, the last text stays.
    func cancel() async {
        guard phase == .recording else { return }
        cleanUpMic()
        UserDefaults.standard.removeObject(forKey: "recordingOpen")
        await endActivity()
        samples = []
        trace("cancel")
    }

    // The recording as .m4a for Send (messengers play it; CAF they often don't): the same AAC, only rewrapped.
    private func shareable(_ caf: URL?) async -> URL? {
        guard let caf else { return nil }
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: m4a)
        guard let x = AVAssetExportSession(asset: AVURLAsset(url: caf), presetName: AVAssetExportPresetPassthrough) else { return caf }
        do { try await x.export(to: m4a, as: .m4a); return m4a } catch { trace("m4a failed \(error)"); return caf }
    }

    private func cleanUpMic() {
        mic?.inputNode.removeTap(onBus: 0); mic?.stop(); mic = nil
        file = nil   // closes the file
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); trace("audio session off") }
        catch { trace("audio session off failed \(error)") }
        UIApplication.shared.isIdleTimerDisabled = false
        levels = Array(repeating: 0, count: 11)
        if phase == .recording { phase = .idle }
    }

    // Text from sound: on screen, on the clipboard, given back to the shortcut. In the background iOS allows about 30 s
    // more; Parakeet needs 3 s for a minute of speech there (on the CPU 7x real time, «Measured»).
    private func finish(_ pcm: [Float]) async -> String {
        phase = .transcribing
        let bg = UIApplication.shared.beginBackgroundTask(withName: "transcribe") { trace("background time over") }
        defer { UIApplication.shared.endBackgroundTask(bg); phase = .idle }
        do {
            try await load()
            let e = engine
            let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                e.queue.async { c.resume(with: Result { try e.transcribe(pcm) }) }
            }
            trace("text \(result.count) chars")
            guard !result.isEmpty else { problem = String(localized: "No speech found"); return "" }
            text = result
            if Dictation.copies { UIPasteboard.general.string = result }
            // History (brief C): the text and its audio as the first row of the list, opened.
            if let r = History.shared.add(text: result, samples: pcm, model: current?.id ?? "",
                                          language: UserDefaults.standard.string(forKey: "language")) { Shelf.shared.added(r) }
            return result
        } catch {
            trace("transcribe failed \(error)")
            problem = String(localized: "Transcription failed")
            return ""
        }
    }

    // A recording iOS ended with the app (memory, a crash) is still on disk, AAC in CAF readable up to its last
    // packet: at the next launch its text is made as if Stop had been pressed.
    func recover() {
        guard UserDefaults.standard.bool(forKey: "recordingOpen") else { return }
        UserDefaults.standard.removeObject(forKey: "recordingOpen")
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent("recording.caf")
        guard phase == .idle, current != nil, let pcm = try? readMedia(caf), pcm.count > 16000 / 2 else { return }
        trace("recovered \(String(format: "%.1f", Double(pcm.count) / 16000)) s")
        Task { audio = await shareable(caf); _ = await finish(pcm) }
    }

    // MARK: the model

    // Loads the chosen model once and keeps it; the words, the replacements and the language go in with it.
    // One load at a time: the launch's preload and a recording's start used to load the same model twice at once
    // (seen in the log 2026-11-11), a second gigabyte mapped for nothing.
    @ObservationIgnored private var loading: (id: String, task: Task<Void, Error>)?
    func load() async throws {
        guard let m = current else { throw Failure.noModel }
        if loadedID == m.id { return }
        if let l = loading, l.id == m.id { return try await l.task.value }
        let e = engine, path = m.path.path
        let task = Task {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                e.queue.async { c.resume(with: Result { try e.load(path: path) }) }
            }
        }
        loading = (m.id, task)
        defer { if loading?.id == m.id { loading = nil } }
        try await task.value
        loadedID = m.id
        passSettings()
        trace("loaded \(m.id)")
    }

    func preload() { Task { try? await load() } }

    // The engine gets its own copy on its queue, as on the Mac (entry.swift, passWords).
    func passSettings() {
        let all = Words.words, preset = Set(presetWords.map { $0.lowercased() }), pairs = Words.replacements
        let own = all.filter { !preset.contains($0.lowercased()) }, builtIn = all.filter { preset.contains($0.lowercased()) }
        let code = UserDefaults.standard.string(forKey: "language").flatMap { c in current?.languages.contains(c) == true ? c : nil }
        let e = engine
        e.queue.async { e.ownWords = own; e.builtIn = builtIn; e.pairs = pairs; e.forced = code }
    }

    func download(_ m: ASRModel) {
        guard download == nil else { return }
        try? FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        // Models are a gigabyte each and come back from the network: never into the iPhone's iCloud backup. The history
        // beside them is the person's own and is backed up, as Voice Memos' recordings are.
        var folder = modelsFolder; var v = URLResourceValues(); v.isExcludedFromBackup = true; try? folder.setResourceValues(v)
        downloading = (m.id, 0)
        let d = Download(url: m.url, target: m.path, sha: m.sha256, size: m.size, progress: { p in
            Task { @MainActor in if Dictation.shared.downloading?.id == m.id { Dictation.shared.downloading = (m.id, p) } }
        }, done: { failure in
            Task { @MainActor in
                let me = Dictation.shared
                me.download = nil; me.downloading = nil
                if let failure { me.problem = failure } else { me.modelID = m.id; me.preload() }
            }
        })
        download = d
        d.start()
    }

    func cancelDownload() { download?.cancel(); download = nil; downloading = nil }

    func delete(_ m: ASRModel) {
        if modelID == m.id { engine.queue.sync { engine.unload() }; modelID = nil }
        try? FileManager.default.removeItem(at: m.path)
        // The last model takes its folder with it, and the app's folder when nothing else is left (the history stays).
        if !phoneModels.contains(where: { $0.isHere }) {
            try? FileManager.default.removeItem(at: modelsFolder)
            if (try? FileManager.default.contentsOfDirectory(atPath: appFolder.path))?.isEmpty == true { try? FileManager.default.removeItem(at: appFolder) }
        }
    }

    // MARK: transcribe again (history)

    // With any downloaded model: loaded for this one job, the chosen one comes back after; the row's text is replaced
    // and it says which model made it. Not while recording.
    func again(_ r: Recording, with m: ASRModel) {
        guard phase == .idle, let u = r.audioURL else { return }
        let id = r.objectID, back = current
        Shelf.shared.busy.insert(id)
        let e = engine
        Task {
            let result = await withCheckedContinuation { (c: CheckedContinuation<Result<String, Error>, Never>) in
                e.queue.async {
                    c.resume(returning: Result {
                        let pcm = try readMedia(u)
                        if m.id != back?.id { try e.load(path: m.path.path) }
                        defer { if m.id != back?.id, let b = back { try? e.load(path: b.path.path) } }
                        return try e.transcribe(pcm)
                    })
                }
            }
            Shelf.shared.busy.remove(id)
            switch result {
            case .success(let t) where !t.isEmpty:
                History.shared.edit(r, text: t); r.model = m.id; r.edited = nil; try? r.managedObjectContext?.save()
                if Dictation.copies { UIPasteboard.general.string = t }
            case .success: problem = String(localized: "No speech found")
            case .failure: problem = String(localized: "Transcription failed")
            }
        }
    }

    // MARK: Live Activity: one at a time, ended before the text is made

    // Only the activities that were there before this one are ended: a task that ended «all of them» ran after the
    // request and took the new one with it (2026-11-11: nothing in the Dynamic Island while recording).
    private func startActivity() {
        let old = Activity<RecordingAttributes>.activities
        if !old.isEmpty { Task { for a in old { await a.end(nil, dismissalPolicy: .immediate) } } }
        do {
            activity = try Activity.request(attributes: RecordingAttributes(),
                                            content: .init(state: .init(started: started, transcribing: false), staleDate: nil))
            trace("activity started, enabled \(ActivityAuthorizationInfo().areActivitiesEnabled), old \(old.count)")
        } catch { trace("activity failed \(error)") }
    }

    // The island's wave: the last 5 s in bars of 0.25 s (the mean of five 50 ms bins), 0...100, sent four times a
    // second; each bar keeps its number from the start, so the island slides the same bars (IslandWave).
    private func updateActivity() {
        guard let activity else { return }
        let n = history.count / 5, from = max(0, n - 20)
        let levels: [UInt8] = (from..<n).map { k in
            let chunk = history[(k * 5)..<(k * 5 + 5)]
            return UInt8(min(100, max(0, chunk.reduce(0, +) / 5 * 100)))
        }
        let state = RecordingAttributes.ContentState(started: started, transcribing: false, levels: levels, first: from)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity() async {
        let all = Activity<RecordingAttributes>.activities
        for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        activity = nil
        trace("activities ended \(all.count), left \(Activity<RecordingAttributes>.activities.filter { $0.activityState == .active }.count)")
    }

    // At launch: a Live Activity left by a recording iOS ended with the app would otherwise stay up to eight hours.
    func closeLeftovers() {
        guard phase == .idle else { return }
        let left = Activity<RecordingAttributes>.activities
        guard !left.isEmpty else { return }
        trace("leftover activities \(left.count)")
        Task { for a in left { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    // MARK: RecordingHost (shared/intents.swift)

    func startFromOutside() -> LocalizedStringResource? {
        trace("intent start, phase \(phase)")
        return start()
    }
    func stopFromOutside() async -> String {
        trace("intent stop, phase \(phase)")
        return await stop()
    }
}
