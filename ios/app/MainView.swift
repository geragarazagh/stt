// The one screen, in the form of Voice Memos on iOS 27 (his choice 2026-11-11 13:05, stt-iphone.md): since history
// (his choice 15:02, stt.md «Decisions») the list of every dictation (HistoryList.swift), Apple's record control at the
// bottom, and while recording a card that rises from the bottom with the
// timer, the running wave, Cancel and Stop. The card is a system sheet, so it moves, dims what is behind it and adapts
// to the iPhone Duo as every Apple sheet does; nothing here animates by hand except the wave and the timer.
// The moves, all the system's own springs: Record dims the button and the card rises; Stop freezes the timer and the
// wave, which greys while the text is made, a spinner in the ring; the card goes down and the text lands as the first
// row of the list, opened. Cancel lowers the card and leaves the screen as it was.
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
            .navigationTitle(d.current == nil && Shelf.shared.items.isEmpty ? "" : String(localized: "Recordings"))
            .safeAreaBar(edge: .bottom) {
                if d.current != nil && editMode == .inactive && !Shelf.shared.editingText {
                    RecordRing(active: false)
                        .opacity(d.phase == .idle ? 1 : 0)   // under the card it would show through the glass as a red smudge
                        .animation(.smooth, value: d.phase)
                        .padding(.bottom, 8)
                }
            }
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
            .sheet(isPresented: Binding(get: { d.phase != .idle }, set: { _ in })) {
                RecordingCard()
                    .presentationDetents([.height(340)])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
            }
            .onChange(of: d.phase) { _, p in if p != .idle { settings = false; editMode = .inactive } }
            .alert(d.problem ?? "", isPresented: Binding(get: { d.problem != nil && d.phase == .idle }, set: { if !$0 { d.problem = nil } })) {
                Button("OK", role: .cancel) {}
            }
            #if DEBUG
            .onAppear { if Demo.sheet != nil { settings = true } }
            #endif
        }
    }
}

// The card while recording and while the text is made. Cancel sits where every Apple sheet keeps it, the top leading
// corner (iOS draws it as the round glass ✕), so the bottom holds only Stop, centred, as in Voice Memos: his 13:25 look
// found Cancel and Stop side by side «сбито» left and right.
struct RecordingCard: View {
    private var d: Dictation { Dictation.shared }
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Clock(started: d.started, stopped: d.stopped)
                RunningWave(history: d.history, started: d.started, stopped: d.stopped)
                    .frame(height: 96)
                RecordRing(active: true)
                Spacer(minLength: 0)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Always there, only off while the text is made: a bar that loses its one item collapses and the
                    // timer under it jumps up.
                    Button(role: .cancel) { Task { await d.cancel() } } label: { Label("Cancel", systemImage: "xmark") }
                        .disabled(d.phase != .recording)
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
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

// Apple's record control: a ring, and inside it a red dot that becomes a red square while recording; a spinner in the
// ring while the text is made. The same control at the bottom of the screen and on the card, so the press looks like
// one button changing.
struct RecordRing: View {
    var active: Bool   // on the card
    private var d: Dictation { Dictation.shared }
    private var recording: Bool { active && d.phase == .recording }
    var body: some View {
        Button { toggle() } label: {
            ZStack {
                Circle().strokeBorder(Color(.systemGray3), lineWidth: 4)
                if active && d.phase == .transcribing {
                    ProgressView().controlSize(.large).transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: recording ? 8 : 31, style: .continuous)
                        .fill(.red)
                        .frame(width: recording ? 30 : 62, height: recording ? 30 : 62)
                        .transition(.opacity)
                }
            }
            .frame(width: 76, height: 76)
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
