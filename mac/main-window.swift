// The main window since history (his choice 2026-11-11, stt.md «Decisions», History): Voice Memos' window on the Mac.
// The recordings on the left, newest first, the record button under them; the open one on the right, its text editable
// and its audio under it; the folders All Recordings and Recently Deleted in a sidebar (deleted ones stay there 30 days,
// his choice 2026-11-11, as Voice Memos). Today's small window became the Settings window (⌘,). One logic with the iPhone app: the same
// shelf, the same actions (copy, share, transcribe again, show in Finder, delete), the same words.
// - Selection is the system's own, as in Finder and Voice Memos: ⌘A, Shift for a range, ⌘-click one by one; ⌫ moves
//   to Recently Deleted (nothing asked, nothing lost yet), there it deletes for ever after one question; ⌘C copies the selected texts; right-click acts on the selection.
// - Search filters by the text.
// - While the window is open STT is a normal app (Dock icon, menu bar: Settings under ⌘,), as a window one works in should
//   be (rules.md, section 3); closed, it goes back to the background with the hot key, as before.
// - SwiftUI as macOS 13 has it (NavigationSplitView, List selection, searchable, contextMenu(forSelectionType:)); nothing
//   newer, since STT runs on 13.
import AppKit
import AVFoundation
import CoreData
import SwiftUI

// What the window shows and what it asks the app to do.
@MainActor final class Shelf: ObservableObject {
    static let shared = Shelf()
    enum Phase { case idle, recording, transcribing }
    enum Folder: Hashable { case all, deleted }
    @Published var items: [Recording] = []
    @Published var trash: [Recording] = []
    @Published var folder: Folder = .all
    @Published var phase: Phase = .idle
    @Published var started = Date()
    @Published var stopped: Date?
    @Published var wave: [Float] = []            // loudness of every 50 ms of the recording so far, 0...1
    @Published var newest: NSManagedObjectID?    // selected and shown after a recording lands
    @Published var busy: Set<NSManagedObjectID> = []   // transcribing again
    @Published var keep: Keep = History.shared.keep
    @Published var demoSelection = 0   // the test copy's shots only (app-menu.swift, demo())
    var demoAsk = false

    var record: () -> Void = {}
    var cancel: () -> Void = {}
    var again: (Recording, ASRModel) -> Void = { _, _ in }
    var settings: () -> Void = {}
    var hotKey: () -> String = { "" }

    var shown: [Recording] { folder == .all ? items : trash }
    func reload() { items = History.shared.all(); trash = History.shared.trash(); keep = History.shared.keep }

    func added(_ r: Recording) { folder = .all; reload(); newest = r.objectID }

    func pick(_ ids: Set<NSManagedObjectID>) -> [Recording] { (items + trash).filter { ids.contains($0.objectID) } }
    func delete(_ ids: Set<NSManagedObjectID>) { History.shared.delete(pick(ids)); reload() }
    func recover(_ ids: Set<NSManagedObjectID>) { History.shared.recover(pick(ids)); reload() }
    func erase(_ ids: Set<NSManagedObjectID>) { History.shared.erase(pick(ids)); reload() }

    func copy(_ ids: Set<NSManagedObjectID>) {
        let texts = pick(ids).compactMap(\.text)
        guard !texts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
    }
}

@MainActor final class MainWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var closed: () -> Void = {}
    // Audio or video dropped anywhere on the window is transcribed to a .txt beside it, as a drop on Settings does.
    let drop = WindowDrop(frame: .zero)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "STT"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let host = NSHostingController(rootView: ShelfView().environmentObject(Shelf.shared))
        // The window keeps the size it is given or the person's own; SwiftUI sets only the smallest size, at which the
        // list, the open text and the player all still fit (ShelfView's frame). With no minimum it could be dragged to
        // nothing (his recording 2026-11-11 17:58: «меньше ты не будешь делать»); window.minSize alone was overridden
        // by the hosting controller.
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 820, height: 520))   // the controller's view set it to the minimum on macOS 13
        drop.frame = host.view.bounds
        drop.autoresizingMask = [.width, .height]
        host.view.addSubview(drop)
        window.delegate = self
        if !window.setFrameUsingName("STT") { window.center() }
        window.setFrameAutosaveName("STT")
    }

    func show() {
        Shelf.shared.reload()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) { closed() }
}

// MARK: views

// Voice Memos' three columns: the folders (All Recordings, Recently Deleted), the recordings, the open one. The folders
// are hidden at first, as in Voice Memos, except on macOS 13, which has no toolbar here to show them again.
struct ShelfView: View {
    @EnvironmentObject var shelf: Shelf
    @State private var selection: Set<NSManagedObjectID> = []
    @State private var search = ""
    @State private var erasing: Set<NSManagedObjectID> = []   // asked once: Delete Forever
    @State private var columns: NavigationSplitViewVisibility = {
        if #available(macOS 14, *) { return .doubleColumn } else { return .all }
    }()
    @FocusState private var listFocused: Bool   // the list takes the keys first: ⌘A selects recordings, not text

    var inTrash: Bool { shelf.folder == .deleted }
    var shown: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? shelf.shown : shelf.shown.filter { ($0.text ?? "").localizedStandardContains(q) }
    }
    var picked: [Recording] { shelf.shown.filter { selection.contains($0.objectID) } }

    // ⌫, the trash button and Delete: to Recently Deleted at once; there, for ever after one question.
    func remove(_ ids: Set<NSManagedObjectID>) {
        guard !ids.isEmpty else { return }
        if inTrash { erasing = ids } else { shelf.delete(ids); selection.subtract(ids) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { shelf.folder }, set: { if let f = $0 { shelf.folder = f; selection = [] } })) {
                Label { HStack { Text(L("All Recordings")); Spacer(); Text("\(shelf.items.count)").foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "waveform") }.tag(Shelf.Folder.all)
                Label { HStack { Text(L("Recently Deleted")); Spacer(); Text("\(shelf.trash.count)").foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "trash") }.tag(Shelf.Folder.deleted)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)   // «Недавно удаленные» and its count whole
        } content: {
            VStack(spacing: 0) {
            // macOS 13 puts no toolbar into a window AppKit made (SwiftUI's toolbar bridging is 14+): the search field
            // stands above the list there; delete and share stay on the right click, ⌫ and the buttons for several.
            if #unavailable(macOS 14) {
                TextField(L("Search Recordings"), text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.top, 8)
            }
            Group {
                if shelf.shown.isEmpty {
                    if inTrash {
                        Empty(symbol: "trash", title: "No Recordings", text: "")
                    } else {
                        Empty(symbol: "waveform", title: shelf.keep == .never ? "History Is Off" : "No Recordings",
                              text: shelf.keep == .never ? "Recordings are not kept. History can be turned on in Settings."
                                                         : String(format: L("Recording: %@ or the record button. Every recording lands here as text."), shelf.hotKey()))
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(shown, id: \.objectID) { r in Row(r: r, trash: inTrash).tag(r.objectID) }
                    }
                    .contextMenu(forSelectionType: NSManagedObjectID.self) { ids in
                        Actions(ids: ids, trash: inTrash, remove: { remove($0) }, recover: { shelf.recover($0); selection.subtract($0) })
                    }
                    .focused($listFocused)
                    .onAppear { listFocused = true }
                    .onDeleteCommand { remove(selection) }
                    .onCopyCommand {
                        picked.compactMap(\.text).isEmpty ? [] : [NSItemProvider(object: picked.compactMap(\.text).joined(separator: "\n\n") as NSString)]
                    }
                }
            }
            // Under the list, not over it: the list ends above the button, as in Voice Memos. In Recently Deleted its
            // two buttons instead, as there.
            if inTrash {
                HStack {
                    Button(L("Recover All")) { shelf.recover(Set(shelf.trash.map(\.objectID))); selection = [] }
                    Spacer()
                    Button(L("Delete All")) { erasing = Set(shelf.trash.map(\.objectID)) }
                }
                .disabled(shelf.trash.isEmpty)
                .padding(12)
            } else {
                RecordBar()
            }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            Group {
            if picked.count == 1, let r = picked.first {
                Detail(r: r, trash: inTrash, recover: { shelf.recover([r.objectID]); selection = [] }).id(r.objectID)
            } else if picked.count > 1 {
                Empty(symbol: "square.stack", title: String(format: L("%d Recordings Selected"), picked.count), text: "") {
                    HStack {
                        if inTrash {
                            Button(L("Recover")) { shelf.recover(selection); selection = [] }
                            Button(L("Delete Forever…")) { erasing = selection }
                        } else {
                            Button(L("Copy Texts")) { shelf.copy(selection) }
                            Button(L("Delete")) { remove(selection) }
                        }
                    }
                    .padding(.top, 8)
                }
            } else {
                Empty(symbol: "text.alignleft", title: "No Recording Selected", text: "")
            }
            }
            // The player's three buttons, its times and the model's name in one row need this much.
            .navigationSplitViewColumnWidth(min: 340, ideal: 480)
        }
        .frame(minWidth: 640, minHeight: 440)
        .modifier(SearchInToolbar(text: $search))
        .toolbar {
            ToolbarItemGroup {
                if picked.count == 1, let r = picked.first, !inTrash { ShareMenu(r: r) }
                Button { remove(selection) } label: { Label(L("Delete"), systemImage: "trash") }
                    .disabled(selection.isEmpty)
                    .help(L(inTrash ? "Delete Forever…" : "Delete"))
            }
        }
        .alert(L(erasing.count == shelf.trash.count && erasing.count > 1 ? "Are you sure you want to permanently delete all recordings?" : "Delete Forever"),
               isPresented: Binding(get: { !erasing.isEmpty }, set: { if !$0 { erasing = [] } })) {
            Button(L("Delete Forever"), role: .destructive) {
                shelf.erase(erasing); selection.subtract(erasing); erasing = []
            }
            Button(L("Cancel"), role: .cancel) { erasing = [] }
        } message: {
            Text(L(erasing.count == 1 ? "This recording will be deleted. This action cannot be undone."
                                      : "These recordings will be deleted. This action cannot be undone."))
        }
        .onReceive(shelf.$demoSelection) { n in
            guard n > 0 else { return }
            selection = Set(shelf.shown.prefix(n).map(\.objectID))
            if shelf.demoAsk { erasing = selection }
        }
        .onReceive(shelf.$newest) { id in
            guard let id else { return }
            search = ""; selection = [id]
        }
        .onReceive(shelf.$folder) { f in search = ""; if f == .deleted { columns = .all } }   // where one is stays in sight
        .onReceive(shelf.$items) { items in
            guard !inTrash else { return }
            let ids = Set(items.map(\.objectID)); selection.formIntersection(ids)
            if selection.isEmpty, let first = items.first, shelf.newest == nil { selection = [first.objectID] }
        }
    }
}

// What the right click offers, for one or several recordings; in Recently Deleted, Recover and Delete Forever.
struct Actions: View {
    @EnvironmentObject var shelf: Shelf
    let ids: Set<NSManagedObjectID>
    let trash: Bool
    let remove: (Set<NSManagedObjectID>) -> Void
    let recover: (Set<NSManagedObjectID>) -> Void
    var recs: [Recording] { shelf.pick(ids) }
    var body: some View {
        if !recs.isEmpty {
            if trash {
                Button(L("Recover")) { recover(ids) }
                Divider()
                Button(L("Delete Forever…")) { remove(ids) }
            } else {
                Button(L(recs.count == 1 ? "Copy Text" : "Copy Texts")) { shelf.copy(ids) }
                if recs.count == 1, let r = recs.first {
                    ShareMenu(r: r)
                    AgainMenu(r: r)
                    if let u = r.audioURL { Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                }
                Divider()
                Button(L("Delete")) { remove(ids) }
            }
        }
    }
}

struct ShareMenu: View {
    @ObservedObject var r: Recording
    var body: some View {
        Menu {
            ShareLink(item: r.text ?? "") { Text(L("Text")) }
            if let u = r.audioURL { ShareLink(item: u) { Text(L("Audio")) } }
        } label: { Label(L("Share"), systemImage: "square.and.arrow.up") }
        .help(L("Share"))
    }
}

// Transcribe again with any downloaded model; the one that made the text carries a check mark.
struct AgainMenu: View {
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var r: Recording
    var body: some View {
        Menu(L("Transcribe Again")) {
            ForEach(models.filter(\.isHere), id: \.id) { m in
                Button { shelf.again(r, m) } label: {
                    if m.id == r.model { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                }
            }
        }
        .disabled(r.audioURL == nil || shelf.busy.contains(r.objectID) || shelf.phase != .idle)
    }
}

struct Row: View {
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var r: Recording
    var trash = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.text ?? "").lineLimit(2)
            HStack {
                Text(trash ? daysLeft(r) : when(r.created ?? Date()))
                Spacer()
                if shelf.busy.contains(r.objectID) { ProgressView().controlSize(.small) }
                Text(length(r.duration)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// The open recording: its text, which can be changed in place, and its audio.
struct Detail: View {
    @ObservedObject var r: Recording
    var trash = false
    var recover: () -> Void = {}
    @State private var draft = ""
    @StateObject private var player = Player()
    var body: some View {
        VStack(spacing: 0) {
            if trash {
                // Recently Deleted: read only, as there; one button brings it back.
                HStack {
                    Text(daysLeft(r)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Recover"), action: recover)
                }
                .padding(.horizontal, 18).padding(.top, 12)
            }
            TextEditor(text: $draft)
                .disabled(trash)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14).padding(.top, 10)
                .onAppear { draft = r.text ?? "" }
                .onChange(of: draft) { t in History.shared.edit(r, text: t) }
                .onReceive(r.objectWillChange) { _ in DispatchQueue.main.async { if (r.text ?? "") != draft { draft = r.text ?? "" } } }
            Divider()
            if let u = r.audioURL {
                PlayerBar(player: player, model: modelTitle(r.model)).onAppear { player.load(u) }
            } else {
                Text("The audio of this recording is not on this Mac.").font(.caption).foregroundStyle(.secondary).padding(14)
            }
        }
        .onDisappear { player.stop() }
    }
}

func modelTitle(_ id: String?) -> String { models.first { $0.id == id }?.title ?? (id ?? "") }

final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    private var p: AVAudioPlayer?
    private var timer: Timer?

    func load(_ u: URL) {
        p = try? AVAudioPlayer(contentsOf: u); p?.delegate = self; p?.prepareToPlay()
        duration = p?.duration ?? 0; time = 0
    }
    func toggle() {
        guard let p else { return }
        if p.isPlaying { p.pause(); playing = false; timer?.invalidate() }
        else {
            p.play(); playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.time = self?.p?.currentTime ?? 0 }
        }
    }
    func seek(_ t: Double) { p?.currentTime = max(0, min(duration, t)); time = p?.currentTime ?? 0 }
    func stop() { p?.stop(); playing = false; timer?.invalidate() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playing = false; self.timer?.invalidate(); self.time = 0 }
    }
}

struct PlayerBar: View {
    @ObservedObject var player: Player
    let model: String
    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 0.01))
                .controlSize(.small)
            HStack {
                Text(length(player.time)).monospacedDigit()
                Spacer()
                Text("-" + length(max(0, player.duration - player.time))).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            ZStack {
                HStack(spacing: 26) {
                    Button { player.seek(player.time - 15) } label: { Image(systemName: "gobackward.15") }
                        .help(L("Back 15 Seconds"))
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2) }
                        .keyboardShortcut(.space, modifiers: [])
                        .help(L(player.playing ? "Pause" : "Play"))
                    Button { player.seek(player.time + 15) } label: { Image(systemName: "goforward.15") }
                        .help(L("Forward 15 Seconds"))
                }
                .buttonStyle(.borderless).font(.title3)
                HStack { Text(model).font(.caption).foregroundStyle(.secondary); Spacer() }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

// Under the list: Apple's record control. While recording, the running wave, the time in hundredths and Stop; a ✕ to
// cancel (nothing kept, as the Cancel Recording key); while the text is made, the wave greys and a spinner turns.
struct RecordBar: View {
    @EnvironmentObject var shelf: Shelf
    var body: some View {
        VStack(spacing: 8) {
            if shelf.phase != .idle {
                HStack {
                    Button { shelf.cancel() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .disabled(shelf.phase != .recording).help(L("Cancel Recording"))
                    Spacer()
                    Clock(started: shelf.started, stopped: shelf.stopped)
                    Spacer()
                    Image(systemName: "xmark.circle.fill").font(.title3).hidden()
                }
                Wave(levels: shelf.wave, started: shelf.started, stopped: shelf.stopped).frame(height: 36)
            }
            Button { shelf.record() } label: { Ring(phase: shelf.phase) }
                .buttonStyle(.plain)
                .disabled(shelf.phase == .transcribing)
                .help(shelf.phase == .recording ? L("Stop Recording") : L("Record") + " " + shelf.hotKey())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: shelf.phase)
    }
}

struct Ring: View {
    let phase: Shelf.Phase
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 3)
            if phase == .transcribing { ProgressView().controlSize(.small) }
            else {
                RoundedRectangle(cornerRadius: phase == .recording ? 4 : 17, style: .continuous)
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: phase == .recording ? 16 : 34, height: phase == .recording ? 16 : 34)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
}

struct Clock: View {
    let started: Date, stopped: Date?
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.01, paused: stopped != nil)) { t in
            let cs = Int(max(0, (stopped ?? t.date).timeIntervalSince(started)) * 100)
            let sep = Locale.current.decimalSeparator ?? "."
            Text(String(format: "%02d:%02d\(sep)%02d", cs / 6000, cs / 100 % 60, cs % 100))
                .font(.system(size: 20, weight: .light).monospacedDigit())
        }
    }
}

// The recording so far, newest at the right edge, 50 ms a bar; red while recording, grey once stopped.
struct Wave: View {
    let levels: [Float], started: Date, stopped: Date?
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: stopped != nil)) { t in
            Canvas { ctx, size in
                let elapsed = (stopped ?? t.date).timeIntervalSince(started)
                let pitch: CGFloat = 4, bar: CGFloat = 2, perSecond = pitch * 20
                let color = stopped == nil ? Color(nsColor: .systemRed) : Color(nsColor: .tertiaryLabelColor)
                let first = max(0, levels.count - Int(size.width / pitch) - 2)
                for i in first..<levels.count {
                    let x = size.width - CGFloat(elapsed - Double(i) * 0.05) * perSecond
                    guard x > -bar else { continue }
                    let h = max(bar, CGFloat(levels[i]) * size.height)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h), cornerRadius: 1), with: .color(color))
                }
            }
        }
    }
}

struct SearchInToolbar: ViewModifier {
    @Binding var text: String
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.searchable(text: $text, placement: .toolbar, prompt: Text(L("Search Recordings"))) }
        else { content }
    }
}

// The empty states, as the system's own (ContentUnavailableView is macOS 14+).
struct Empty<Extra: View>: View {
    let symbol: String, title: String, text: String
    var extra: Extra
    init(symbol: String, title: String, text: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.symbol = symbol; self.title = title; self.text = text; self.extra = extra()
    }
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary).padding(.bottom, 4)
            Text(L(title)).font(.headline)
            if !text.isEmpty { Text(L(text)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            extra
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// «29 дней» in Recently Deleted: the system's own words and plural forms.
@MainActor func daysLeft(_ r: Recording) -> String {
    let f = DateComponentsFormatter(); f.allowedUnits = [.day]; f.unitsStyle = .full
    return f.string(from: DateComponents(day: History.daysLeft(r))) ?? ""
}

// «0:08», as Voice Memos writes a length.
func length(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

// «14:52» today, «Yesterday», then a date: Voice Memos' way, in the person's language.
func when(_ d: Date) -> String {
    let f = DateFormatter()
    if Calendar.current.isDateInToday(d) { f.timeStyle = .short; return f.string(from: d) }
    f.dateStyle = .medium; f.doesRelativeDateFormatting = true
    return f.string(from: d)
}
