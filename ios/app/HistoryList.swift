// The main screen since history (his choice 2026-11-11 15:02, stt.md «Decisions», History): Voice Memos' list. Every
// dictation is a row, newest first; a tap opens the row in place (the whole text, editable, its audio, copy, «⋯»,
// delete), as Voice Memos opens a recording; a left swipe offers Delete, Share and Copy; a long press the same menu as
// «⋯»; Select gives check marks and a bottom bar (Select All, Share, Delete). Delete moves a recording to Recently
// Deleted for 30 days and asks nothing, as Voice Memos (his choice 2026-11-11); that folder is the last row of the list
// while it holds anything, and there Recover or Delete Forever (asked once). The record button and the recording card
// stay as they were (MainView): after Stop the card goes down and the new text lands as the first row, open, already
// on the clipboard. One logic with the Mac window (mac/main-window.swift): the same actions and words.
import AVFoundation
import CoreData
import SwiftUI

// What the list shows. Core Data objects are observable, so a row follows its record (an edit, transcribing again).
@MainActor @Observable final class Shelf {
    static let shared = Shelf()
    var items: [Recording] = []
    var trash: [Recording] = []
    var open: NSManagedObjectID?          // the row opened in place
    var busy: Set<NSManagedObjectID> = []  // transcribing again
    var editingText = false                 // the keyboard is up for a row: no record button, no Select (MainView)
    func reload() { items = History.shared.all(); trash = History.shared.trash() }
    func added(_ r: Recording) { reload(); withAnimation(.smooth(duration: 0.45)) { open = r.objectID } }
    func pick(_ ids: Set<NSManagedObjectID>) -> [Recording] { (items + trash).filter { ids.contains($0.objectID) } }
    func delete(_ ids: Set<NSManagedObjectID>) { withAnimation(.smooth) { History.shared.delete(pick(ids)); reload() } }
    func recover(_ ids: Set<NSManagedObjectID>) { withAnimation(.smooth) { History.shared.recover(pick(ids)); reload() } }
    func erase(_ ids: Set<NSManagedObjectID>) { withAnimation(.smooth) { History.shared.erase(pick(ids)); reload() } }
}

struct HistoryList: View {
    @Binding var editMode: EditMode
    @State private var picked: Set<NSManagedObjectID> = []
    @State private var search = ""
    private var shelf: Shelf { Shelf.shared }
    var shown: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? shelf.items : shelf.items.filter { ($0.text ?? "").localizedStandardContains(q) }
    }
    func remove(_ ids: Set<NSManagedObjectID>) {
        shelf.delete(ids); picked.subtract(ids)
        if shelf.items.isEmpty { editMode = .inactive }
    }

    var body: some View {
        Group {
            if shelf.items.isEmpty && shelf.trash.isEmpty {
                ContentUnavailableView(History.shared.keep == .never ? "History Is Off" : "No Recordings",
                                       systemImage: "waveform",
                                       description: Text(History.shared.keep == .never
                                                         ? "Recordings are not kept. History can be turned on in Settings."
                                                         : "Every recording lands here as text."))
            } else {
                List(selection: $picked) {
                    ForEach(shown, id: \.objectID) { r in
                        Row(r: r, selecting: editMode == .active, ask: { remove($0) })
                            .contentShape(Rectangle())
                            // Only outside Select: there a tap must reach the list and tick the row.
                            .modifier(TapToOpen(on: editMode == .inactive) {
                                withAnimation(.smooth) { shelf.open = shelf.open == r.objectID ? nil : r.objectID }
                            })
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { remove([r.objectID]) } label: { Label("Delete", systemImage: "trash") }
                                ShareText(r: r).tint(.blue)
                                Button { copy(r) } label: { Label("Copy", systemImage: "doc.on.doc") }.tint(.gray)
                            }
                            .contextMenu { RecMenu(r: r, ask: { remove($0) }) }
                            .tag(r.objectID)
                    }
                    if !shelf.trash.isEmpty && editMode == .inactive && search.isEmpty {
                        Section {
                            NavigationLink { RecentlyDeleted() } label: {
                                LabeledContent { Text("\(shelf.trash.count)") } label: { Label("Recently Deleted", systemImage: "trash") }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Recordings")
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            if editMode == .active {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(picked.count == shelf.items.count ? "Deselect All" : "Select All") {
                        picked = picked.count == shelf.items.count ? [] : Set(shelf.items.map(\.objectID))
                    }
                    Spacer()
                    ShareLink(items: shelf.items.filter { picked.contains($0.objectID) }.compactMap(\.text)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(picked.isEmpty)
                    Button(role: .destructive) { remove(picked) } label: { Label("Delete", systemImage: "trash") }
                        .disabled(picked.isEmpty)
                }
            }
        }
        .onChange(of: editMode) { _, m in if m == .inactive { picked = [] } }
        .onAppear { History.shared.purge(); shelf.reload() }
    }
}

// Recently Deleted, as in Voice Memos: what was deleted in the last 30 days, the days left under each; swipe to
// Recover or Delete Forever; Select gives Recover and Delete for the ticked ones, or for all when none is ticked.
struct RecentlyDeleted: View {
    @State private var editMode: EditMode = .inactive
    @State private var picked: Set<NSManagedObjectID> = []
    @State private var erasing: Set<NSManagedObjectID> = []
    @Environment(\.dismiss) private var dismiss
    private var shelf: Shelf { Shelf.shared }
    var body: some View {
        List(selection: $picked) {
            ForEach(shelf.trash, id: \.objectID) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.text ?? "").lineLimit(2)
                    HStack { Text(daysLeft(r)); Spacer(); Text(length(r.duration)).monospacedDigit() }
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { erasing = [r.objectID] } label: { Label("Delete Forever", systemImage: "trash") }
                    Button { shelf.recover([r.objectID]) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }.tint(.blue)
                }
                .tag(r.objectID)
            }
        }
        .listStyle(.plain)
        .overlay { if shelf.trash.isEmpty { ContentUnavailableView("No Recordings", systemImage: "trash") } }
        .navigationTitle("Recently Deleted")
        .environment(\.editMode, $editMode)
        .toolbar {
            if !shelf.trash.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "Done" : "Select") { withAnimation { editMode = editMode == .active ? .inactive : .active } }
                }
            }
            if editMode == .active {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(picked.isEmpty ? "Recover All" : "Recover") {
                        shelf.recover(picked.isEmpty ? Set(shelf.trash.map(\.objectID)) : picked); picked = []; editMode = .inactive
                    }
                    Spacer()
                    Button(picked.isEmpty ? "Delete All" : "Delete", role: .destructive) {
                        erasing = picked.isEmpty ? Set(shelf.trash.map(\.objectID)) : picked
                    }
                }
            }
        }
        .confirmationDialog(erasing.count == shelf.trash.count && erasing.count > 1 ? "Are you sure you want to permanently delete all recordings?" : "Delete Forever",
                            isPresented: Binding(get: { !erasing.isEmpty }, set: { if !$0 { erasing = [] } }), titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) {
                shelf.erase(erasing); picked.subtract(erasing); erasing = []
                if shelf.trash.isEmpty { editMode = .inactive; dismiss() }
            }
        } message: {
            Text(erasing.count == 1 ? "This recording will be deleted. This action cannot be undone."
                                    : "These recordings will be deleted. This action cannot be undone.")
        }
        .onChange(of: shelf.trash.isEmpty) { _, empty in if empty { dismiss() } }
    }
}

// «29 дней»: the system's own words and plural forms.
func daysLeft(_ r: Recording) -> String {
    let f = DateComponentsFormatter(); f.allowedUnits = [.day]; f.unitsStyle = .full
    return f.string(from: DateComponents(day: History.daysLeft(r))) ?? ""
}

struct TapToOpen: ViewModifier {
    let on: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if on { content.onTapGesture(perform: action) } else { content }
    }
}

func copy(_ r: Recording) { if let t = r.text { UIPasteboard.general.string = t } }

// The same actions everywhere: «⋯», the long press.
struct RecMenu: View {
    let r: Recording
    let ask: (Set<NSManagedObjectID>) -> Void
    var body: some View {
        Button { copy(r) } label: { Label("Copy Text", systemImage: "doc.on.doc") }
        Menu {
            ShareLink(item: r.text ?? "") { Label("Text", systemImage: "text.alignleft") }
            if let u = r.audioURL { ShareLink(item: u) { Label("Audio", systemImage: "waveform") } }
        } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Menu {
            ForEach(phoneModels.filter(\.isHere), id: \.id) { m in
                Button { Dictation.shared.again(r, with: m) } label: {
                    if m.id == r.model { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                }
            }
        } label: { Label("Transcribe Again", systemImage: "arrow.clockwise") }
        .disabled(r.audioURL == nil || Dictation.shared.phase != .idle || Shelf.shared.busy.contains(r.objectID))
        Divider()
        Button(role: .destructive) { ask([r.objectID]) } label: { Label("Delete", systemImage: "trash") }
    }
}

struct ShareText: View {
    let r: Recording
    var body: some View { ShareLink(item: r.text ?? "") { Label("Share", systemImage: "square.and.arrow.up") } }
}

struct Row: View {
    @ObservedObject var r: Recording
    let selecting: Bool
    // Read here, not passed in: a row's content is built apart from the list's body, so only what the row itself reads
    // makes it follow (a new recording opened from outside stayed closed when this was a parameter).
    var open: Bool { Shelf.shared.open == r.objectID && !selecting }
    let ask: (Set<NSManagedObjectID>) -> Void
    @State private var draft = ""
    @FocusState private var editing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if open {
                    // The whole text, editable in place; a changed text is kept and, with Copy Text on, copied again.
                    TextField("", text: $draft, axis: .vertical)
                        .focused($editing)
                        .onAppear { draft = r.text ?? "" }
                        .onChange(of: draft) { _, t in History.shared.edit(r, text: t) }
                        .onChange(of: editing) { _, now in
                            Shelf.shared.editingText = now
                            if !now && Dictation.copies { copy(r) }
                        }
                } else {
                    Text(r.text ?? "").lineLimit(2)
                }
                Spacer(minLength: 8)
                if open {
                    Menu { RecMenu(r: r, ask: ask) } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                        .accessibilityLabel("More")
                }
            }
            HStack {
                Text(when(r.created ?? Date()))
                Spacer()
                if Shelf.shared.busy.contains(r.objectID) { ProgressView().controlSize(.mini) }
                Text(length(r.duration)).monospacedDigit()
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if open { Opened(r: r, ask: ask) }
        }
        .padding(.vertical, 4)
        .toolbar {
            if editing { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } } }
        }
    }
}

// The open row's lower part: the audio and the two actions Voice Memos keeps at its sides (here Copy and Delete).
struct Opened: View {
    let r: Recording
    let ask: (Set<NSManagedObjectID>) -> Void
    @State private var player = Player()
    var body: some View {
        VStack(spacing: 6) {
            if r.audioURL != nil {
                Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 0.01))
                HStack { Text(length(player.time)); Spacer(); Text("-" + length(max(0, player.duration - player.time))) }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Button { copy(r) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy Text")
                Spacer()
                if r.audioURL != nil {
                    HStack(spacing: 34) {
                        Button { player.seek(player.time - 15) } label: { Image(systemName: "gobackward.15") }
                            .accessibilityLabel("Back 15 Seconds")
                        Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title) }
                            .accessibilityLabel(player.playing ? "Pause" : "Play")
                        Button { player.seek(player.time + 15) } label: { Image(systemName: "goforward.15") }
                            .accessibilityLabel("Forward 15 Seconds")
                    }
                    .foregroundStyle(.primary)
                } else {
                    Text("The audio of this recording is not on this iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { ask([r.objectID]) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
            }
            .font(.title3)
            .buttonStyle(.borderless)
            .padding(.vertical, 6)
        }
        .padding(.top, 6)
        .onAppear { if let u = r.audioURL { player.load(u) } }
        .onDisappear { player.stop() }
    }
}

@MainActor @Observable final class Player: NSObject, AVAudioPlayerDelegate {
    var playing = false
    var time: Double = 0
    var duration: Double = 0
    @ObservationIgnored private var p: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    func load(_ u: URL) { p = try? AVAudioPlayer(contentsOf: u); p?.delegate = self; duration = p?.duration ?? 0; time = 0 }
    func toggle() {
        guard let p else { return }
        if p.isPlaying { p.pause(); playing = false; timer?.invalidate(); return }
        // Played through the speaker, other sound paused, as Voice Memos plays a memo.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play(); playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { self.time = self.p?.currentTime ?? 0 }
        }
    }
    func seek(_ t: Double) { p?.currentTime = max(0, min(duration, t)); time = p?.currentTime ?? 0 }
    func stop() { p?.stop(); playing = false; timer?.invalidate() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false; self.timer?.invalidate(); self.time = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// «0:08», as Voice Memos writes a length.
func length(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

// «14:52» today, «Yesterday», then a date: Voice Memos' way, in the person's language and region.
func when(_ d: Date) -> String {
    let f = DateFormatter()
    if Calendar.current.isDateInToday(d) { f.timeStyle = .short; return f.string(from: d) }
    f.dateStyle = .medium; f.doesRelativeDateFormatting = true
    return f.string(from: d)
}
