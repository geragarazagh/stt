// Debug builds only: puts the screen into a given state for the simulator shots shown to him (brief D), from launch
// arguments: -demo empty|text|recording|transcribing|first, -sheet settings|dictionary.
#if DEBUG
import ActivityKit
import SwiftUI

enum Demo {
    static var sheet: String? { UserDefaults.standard.string(forKey: "sheet") }

    @MainActor static func apply() {
        guard let state = UserDefaults.standard.string(forKey: "demo") else { return }
        let d = Dictation.shared
        #if targetEnvironment(simulator)
        // A model «here» for the shots: an empty file in its place (the simulator has no Metal for the engine anyway).
        if state != "first", let m = phoneModels.first(where: { $0.id == "whisper-large-v3-turbo" }) {
            try? FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
            if !m.isHere { FileManager.default.createFile(atPath: m.path.path, contents: Data()) }
            d.modelID = m.id
        }
        if state == "first" { try? FileManager.default.removeItem(at: appFolder); d.modelID = nil }
        #endif
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let sample = [
            "ru": "Напомни завтра в девять позвонить в сервис насчёт стиральной машины. И купить батарейки для пульта, две пары, AA.",
            "uk": "Нагадай завтра о дев’ятій зателефонувати в сервіс щодо пральної машини. І купити батарейки для пульта, дві пари, AA.",
            "en": "Remind me tomorrow at nine to call the repair shop about the washing machine. And buy batteries for the remote, two pairs, AA.",
        ][lang] ?? ""
        // Speech-like loudness for the wave: syllables, words, short pauses (a fixed seed, the same in every shot).
        func speech(_ n: Int) -> [Float] {
            var x: UInt64 = 7
            return (0..<n).map { i in
                x = x &* 6364136223846793005 &+ 1442695040888963407
                let r = Float(x >> 40) / Float(1 << 24)
                let word = sin(Float(i) / 2.3) * 0.5 + 0.5, pause = (i / 17) % 5 == 4 ? Float(0.05) : 1
                return min(1, (0.12 + 0.5 * word + 0.38 * r) * pause)
            }
        }
        switch state {
        case "text": d.text = sample; d.audio = FileManager.default.temporaryDirectory.appendingPathComponent("recording.m4a")
        case "recording":
            // The wave keeps growing every 50 ms, as from a microphone, so a shot at any moment looks like the real one.
            let all = speech(4000); d.phase = .recording; d.started = Date().addingTimeInterval(-4.7); d.history = Array(all.prefix(94))
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let n = Int(Date().timeIntervalSince(d.started) / 0.05)
                    if d.phase == .recording, n < all.count { d.history = Array(all.prefix(n)) }
                }
            }
        case "flow":
            // The whole move for a video: empty 1.5 s, record 5 s (the wave grows as from a microphone), Stop, the text
            // made for 2.5 s, the card down and the text in.
            let all = speech(4000)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                d.started = Date(); d.stopped = nil; d.history = []; d.phase = .recording
                let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    MainActor.assumeIsolated { if d.phase == .recording { d.history = Array(all.prefix(Int(Date().timeIntervalSince(d.started) / 0.05))) } }
                }
                try? await Task.sleep(for: .seconds(5))
                t.invalidate(); d.stopped = Date(); d.phase = .transcribing
                try? await Task.sleep(for: .seconds(2.5))
                d.text = sample; d.phase = .idle
            }
        case "island":
            // A Live Activity with a still wave, for the shots of the island (the app then goes to the background).
            let w = speech(20).map { UInt8($0 * 100) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))   // a request before the scene is in front is refused
                do { _ = try Activity.request(attributes: RecordingAttributes(),
                                              content: .init(state: .init(started: Date().addingTimeInterval(-35), transcribing: false, levels: w), staleDate: nil)) }
                catch { print("demo activity: \(error)") }
            }
        case "transcribing":
            let now = Date(); d.phase = .transcribing; d.started = now.addingTimeInterval(-8.59); d.stopped = now; d.history = speech(172)
        default: break
        }
    }
}
#endif
