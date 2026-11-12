// The one screen, in the form of Voice Memos on iOS 27 (his choice 2026-11-11 13:05, stt-iphone.md): since history
// (his choice 15:02, stt.md «Decisions») the list of every dictation (HistoryList.swift) and Apple's record control
// floating over its bottom. Recording, the control itself grows into a card, as in Voice Memos (his 11:20 video of
// 2026-11-12, read frame by frame at 30 fps): the red dot darkens and widens into a panel 8 pt from the screen's sides
// and bottom with corners concentric to the screen's, the list behind fades, then the timer, the running wave, Cancel
// and Stop appear on it. Stop keeps the card while the text is made (a spinner in the ring), then the card shrinks back
// into the dot with a little spring and the text lands as the first row, opened. Cancel shrinks it at once.
// Until then the card was a system sheet that slid up over the dot, and the button sat in a bottom bar whose scroll
// edge effect drew a dark band over the list's end (his «чёрная полоса»); the list now runs under the control.
import SwiftUI

struct MainView: View {
    @State private var settings = false
    @State private var editMode: EditMode = .inactive
    private var d: Dictation { Dictation.shared }

    var body: some View {
        NavigationStack {
            ZStack {
                if d.current == nil && d.phase == .idle && Shelf.shared.items.isEmpty {
                    FirstModel()
                } else {
                    // Stays under the card while recording, dimmed by it, as Voice Memos keeps its list.
                    HistoryList(editMode: $editMode)
                }
            }
            // In Select the title counts the ticked rows, as Voice Memos' «9 Selected».
            .navigationTitle(d.current == nil && Shelf.shared.items.isEmpty ? ""
                             : editMode == .active ? String(localized: "\(Shelf.shared.picked) Selected") : String(localized: "Recordings"))
            .contentMargins(.bottom, 96, for: .scrollContent)   // the last row can scroll above the control
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                if !Shelf.shared.items.isEmpty && d.phase == .idle && !Shelf.shared.editingText {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode == .active ? "Done" : "Select") { withAnimation { editMode = editMode == .active ? .inactive : .active } }
                    }
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            .onChange(of: d.phase) { _, p in if p != .idle { settings = false; editMode = .inactive } }
            .alert(d.problem ?? "", isPresented: Binding(get: { d.problem != nil && d.phase == .idle }, set: { if !$0 { d.problem = nil } })) {
                Button("OK", role: .cancel) {}
            }
            #if DEBUG
            .onAppear { if Demo.sheet != nil { settings = true } }
            #endif
        }
        // Over the navigation bar too: Voice Memos fades its title with the list.
        .overlay { if d.phase != .idle { Color(.systemBackground).opacity(0.55).ignoresSafeArea().transition(.opacity) } }
        .overlay(alignment: .bottom) {
            if d.current != nil && editMode == .inactive && !Shelf.shared.editingText && !Shelf.shared.searching { Recorder() }
        }
        .animation(morph, value: d.phase != .idle)
    }
}

// Open and close: one spring for the shape, measured against Voice Memos (about a third of a second, a small overshoot
// on the way back into the dot).
let morph = Animation.spring(duration: 0.38, bounce: 0.18)

// Apple's record control and the card it becomes: one shape, so the press looks like the button growing. Sizes measured
// on Voice Memos in his video (a 3x screen): the red dot 51 pt, a 3 pt grey ring 59 pt across, its centre 64 pt above
// the screen's bottom; the card 8 pt from the sides and the bottom, 276 pt high.
struct Recorder: View {
    private var d: Dictation { Dictation.shared }
    private var open: Bool { d.phase != .idle }
    @State private var red = 1.0   // the dot's red over the card's grey
    var body: some View {
        GeometryReader { geo in
            let lift = max(geo.safeAreaInsets.bottom, 8) + 4   // the dot's bottom: the home indicator's line
            ZStack(alignment: .bottom) {
                // The ring of the idle control, around the dot; it goes when the dot grows.
                Circle().strokeBorder(Color(.systemGray3), lineWidth: 3)
                    .frame(width: 59, height: 59)
                    .padding(.bottom, lift - 4)
                    .opacity(open ? 0 : 1)
                // The dot that becomes the card: concentric corners never under the dot's own radius.
                // The colour changes in its own transaction (onChange below): an animation set on the shape would carry
                // its size with it, and closing grew back into a big red square for a moment.
                ZStack {
                    ConcentricRectangle(corners: .concentric(minimum: .fixed(25.5)), isUniform: true)
                        .fill(Color(.tertiarySystemBackground))
                    ConcentricRectangle(corners: .concentric(minimum: .fixed(25.5)), isUniform: true)
                        .fill(Color.red.opacity(red))
                }
                    .frame(width: open ? geo.size.width - 16 : 51, height: open ? 276 : 51)
                    .padding(.bottom, open ? 8 : lift)
                    .shadow(color: .black.opacity(open ? 0.25 : 0), radius: 20, y: 4)
                if open {
                    RecordingCard()
                        .frame(width: geo.size.width - 16, height: 276)
                        .padding(.bottom, 8)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.18).delay(0.12)),
                                                removal: .opacity.animation(.easeOut(duration: 0.08))))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .allowsHitTesting(open)   // idle, only the dot's own button below takes a touch; the list stays scrollable
            .ignoresSafeArea(edges: .bottom)
        }
        // Voice Memos' dot darkens first, then grows; closing, the card shrinks dark and reddens at the end.
        // Already recording when the screen appears (the Action Button's cold start): grey from the first frame.
        .onAppear { red = open ? 0 : 1 }
        .onChange(of: open) { _, o in
            withAnimation(o ? .easeOut(duration: 0.12) : .easeIn(duration: 0.2).delay(0.14)) { red = o ? 0 : 1 }
        }
        .overlay(alignment: .bottom) {
            // The idle control's own button: the dot and its ring, nothing else of the screen.
            if !open {
                Button { toggle() } label: { Color.clear.frame(width: 64, height: 64).contentShape(Circle()) }
                    .buttonStyle(.plain)
                    .padding(.bottom, 2)
                    .accessibilityLabel(Text("Record"))
            }
        }
    }
}

// What the card holds while recording and while the text is made: Cancel in the top leading corner as the system's
// round ✕ (where every Apple sheet keeps it; his 13:25 look found Cancel and Stop side by side «сбито»), the clock, the
// running wave and Stop, centred at the bottom as in Voice Memos. Cancel stays, only off while the text is made.
struct RecordingCard: View {
    private var d: Dictation { Dictation.shared }
    var body: some View {
        VStack(spacing: 14) {
            Clock(started: d.started, stopped: d.stopped)
                .padding(.top, 22)
            RunningWave(history: d.history, started: d.started, stopped: d.stopped)
                .frame(height: 96)
            RecordRing(active: true)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topLeading) {
            Button(role: .cancel) { Task { await d.cancel() } } label: {
                Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly).font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(d.phase != .recording)
            .padding(14)
        }
        .animation(.smooth, value: d.phase)
    }
}

// Minutes, seconds and hundredths, as Voice Memos counts: «00:04,71». Stops with Stop.
struct Clock: View {
    var started: Date, stopped: Date?
    var body: some View {
        TimelineView(.animation(paused: stopped != nil)) { t in
            let s = max(0, (stopped ?? t.date).timeIntervalSince(started))
            let cs = Int(s * 100)
            let sep = Locale.current.decimalSeparator ?? ","
            Text(String(format: "%02d:%02d\(sep)%02d", cs / 6000, cs / 100 % 60, cs % 100))
                .font(.system(size: 44, weight: .light).monospacedDigit())
                .contentTransition(.identity)
        }
        .accessibilityHidden(true)
    }
}

// Stop on the card: Apple's ring with the red square of a recording in it (Voice Memos' sizes, 59 pt), a spinner in the
// ring while the text is made. The idle control at the bottom of the screen is the Recorder's own dot and ring.
struct RecordRing: View {
    var active: Bool   // on the card
    private var d: Dictation { Dictation.shared }
    private var recording: Bool { active && d.phase == .recording }
    var body: some View {
        Button { toggle() } label: {
            ZStack {
                Circle().strokeBorder(Color(.systemGray3), lineWidth: 3)
                if active && d.phase == .transcribing {
                    ProgressView().controlSize(.large).transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: recording ? 7 : 25.5, style: .continuous)
                        .fill(.red)
                        .frame(width: recording ? 24 : 51, height: recording ? 24 : 51)
                        .transition(.opacity)
                }
            }
            .frame(width: 59, height: 59)
            .animation(.snappy(duration: 0.3), value: d.phase)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(d.phase != .transcribing && (active || d.phase == .idle))
        .accessibilityLabel(Text(recording ? "Stop Recording" : "Record"))
    }
}

// The recording so far, scrolling to the left as it grows, newest at the right edge: thin red bars, a dotted line where
// it was quiet (Voice Memos' look). Each bar is 50 ms; positions come from the clock, so it moves every frame, not
// every buffer. After Stop it stands still and greys while the text is made.
struct RunningWave: View {
    var history: [Float], started: Date, stopped: Date?
    var body: some View {
        TimelineView(.animation(paused: stopped != nil)) { t in
            Canvas { ctx, size in
                let elapsed = (stopped ?? t.date).timeIntervalSince(started)
                let pitch: CGFloat = 5, bar: CGFloat = 3, perSecond = pitch * 20
                let color: Color = stopped == nil ? .red : Color(.systemGray)
                let first = max(0, history.count - Int(size.width / pitch) - 2)
                for i in first..<history.count {
                    let x = size.width - CGFloat(elapsed - Double(i) * 0.05) * perSecond
                    guard x > -bar else { continue }
                    let h = max(bar, CGFloat(history[i]) * size.height)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h), cornerRadius: bar / 2),
                             with: .color(color))
                }
            }
        }
        .animation(.smooth, value: stopped)
        .accessibilityHidden(true)
    }
}

@MainActor func toggle() {
    let d = Dictation.shared
    switch d.phase {
    case .idle: d.start()
    case .recording: Task { await d.stop() }
    case .transcribing: break   // a press while the text is being made does nothing
    }
}

// No model yet: the same list as in Settings and nothing else, in the app's own look (his word 2026-11-11 13:40: one
// tap and the person is in; no welcome screen nobody sees twice; language, dictionary, copying live in Settings). The
// size is confirmed once before the download (App Review 4.2.3), the one extra tap.
struct FirstModel: View {
    var body: some View {
        List {
            Section { ModelRows() } header: { Text("Choose a Model") }
        }
    }
}
