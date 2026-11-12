// What the app and the widget extension both need: the Live Activity's data, the stub of the engine's error type the
// Shortcuts actions name (the extension compiles shared/intents.swift only for the Control, never runs it), and the
// log every process writes for the Action Button tests (brief D: «logging in every process»).
import ActivityKit
import AppIntents
import Foundation
import SwiftUI

// The recording sign in the Dynamic Island and on the Lock Screen. Apple requires one while an AudioRecordingIntent
// records; here it runs for every recording, so the island always says what the microphone is doing.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var started: Date
        var transcribing: Bool
        var levels: [UInt8] = []   // the voice's last few seconds, 0...100, newest last, for the island's wave
        var first = 0              // the number of levels[0] since the start: the same bar keeps its number
    }
}

// The island's wave, as Voice Memos draws its own: red bars of the last seconds, a dotted line where it was quiet. A
// Live Activity is redrawn only when the app sends a new state (four a second here), so smoothness comes from the
// system's own animation between two states: every bar keeps its number (first + i), and a new state slides the same
// bars left by one step over exactly the time until the next one, instead of a new picture each time (his video
// 2026-11-11: the wave moved «какими-то кадрами»).
struct IslandWave: View {
    var levels: [UInt8]
    var first: Int
    var bars: Int
    var body: some View {
        GeometryReader { g in
            let pitch = g.size.width / CGFloat(bars), bar = max(2, pitch * 0.55)
            let shown = Array(levels.suffix(bars)), start = first + levels.count - shown.count
            ZStack(alignment: .leading) {
                ForEach(shown.indices.map { (n: start + $0, k: $0, v: shown[$0]) }, id: \.n) { b in   // id = the bar's own number
                    let k = b.k, v = b.v
                    let slot = CGFloat(bars - shown.count + k)
                    let h = CGFloat(v) / 100
                    Capsule().fill(.red)
                        .frame(width: bar, height: h < 0.08 ? bar : max(bar, h * g.size.height))
                        .offset(x: slot * pitch)
                        .transition(.opacity)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
        }
        .animation(.linear(duration: 0.25), value: first)
    }
}

// The island's Stop: brings STT forward and stops there, as Voice Memos' does (his word 2026-11-11 14:39): the text is
// made in front of the person, with the GPU, and lands on the screen and the clipboard.
struct StopFromIsland: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let supportedModes: IntentModes = .foreground(.immediate)
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET
        trace("island stop, phase \(Dictation.shared.phase)")
        if Dictation.shared.isRecording { Task { _ = await Dictation.shared.stop() } }
        #endif
        return .result()
    }
}

// Whether the app is recording, for the Record control's state (the extension can't ask the app; the App Group's
// defaults are the one place both read).
enum Shared {
    static let defaults = UserDefaults(suiteName: "group.com.geragaraza.stt")
    static let controlKind = "com.geragaraza.stt.record"
    static var recording: Bool {
        get { defaults?.bool(forKey: "recording") ?? false }
        set { defaults?.set(newValue, forKey: "recording") }
    }
}

// The Record control as a toggle (HIG «Controls»: two states, a symbol for each, the state shown in the Dynamic Island
// when the Action Button runs it). Its action runs in the app, which is brought forward, like Record.
struct ToggleRecording: SetValueIntent {
    static let title: LocalizedStringResource = "Record"
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Recording") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET
        trace("control \(value ? "on" : "off"), phase \(Dictation.shared.phase)")
        if value { if !Dictation.shared.isRecording { Dictation.shared.start() } }
        else if Dictation.shared.isRecording { _ = await Dictation.shared.stop() }
        #endif
        return .result()
    }
}

#if WIDGET
enum Failure: Error { case noModel, stopped, noSound }
#endif

// One line per event to Documents/events.log (app) or the extension's own folder: when, which process, what. Read off
// the phone with devicectl during the Action Button tests; removed with the test builds' logging before brief E.
func trace(_ s: String) {
    #if DEBUG
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("events.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(ProcessInfo.processInfo.processName) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    #endif
}
