// Settings in the Mac window's order and words (stt.md, «How it works»): Model, Language; Dictionary; History: how much is
// kept (brief C). Transcribe File and Save Subtitles are the Mac's (his word 2026-11-11). What only a Mac has (keys, Open at Login, Pause Media, Mute Sound, Paste Text)
// is not here. A system sheet with a Form: on the iPhone Duo it moves and resizes by itself.
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var words = false
    private var d: Dictation { Dictation.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section { ModelRows() } header: { Text("Model") }
                Section { LanguagePicker() }
                Section { CopyTextToggle() } footer: { CopyTextFooter() }
                Section {
                    NavigationLink("Dictionary") { DictionaryView() }
                }
                Section { KeepPicker() } footer: { Text("Texts and audio stay on this iPhone; the setting is the same on every device with this iCloud account.") }
                Section {} footer: { About() }
            }
            .navigationDestination(isPresented: $words) { DictionaryView() }
            #if DEBUG
            .onAppear { if Demo.sheet == "dictionary" { words = true } }
            #endif
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct About: View {
    var body: some View {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        VStack(spacing: 4) {
            Text("STT \(v)")
            HStack(spacing: 12) {
                Link("Herman Harazha", destination: URL(string: "https://geragaraza.com")!)
                Link("GitHub", destination: URL(string: "https://github.com/geragarazagh/stt")!)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.footnote)
    }
}

// Name, size, Downloaded; a tap on one not here asks with its size first (App Review 4.2.3, and the Mac does the same).
struct ModelRows: View {
    @State private var asking: ASRModel?
    @State private var deleting: ASRModel?
    private var d: Dictation { Dictation.shared }

    var body: some View {
        ForEach(phoneModels, id: \.id) { m in
            Button {
                if m.isHere { d.modelID = m.id; d.preload() } else if d.downloading == nil { asking = m }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).foregroundStyle(.primary)
                        if let dl = d.downloading, dl.id == m.id {
                            ProgressView(value: dl.share).padding(.vertical, 4)
                        } else {
                            Text(m.isHere ? "\(sizeText(m.size)), \(String(localized: "Downloaded"))" : sizeText(m.size))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if d.modelID == m.id && m.isHere { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    if let dl = d.downloading, dl.id == m.id {
                        Button("Cancel", role: .cancel) { d.cancelDownload() }.buttonStyle(.borderless)
                    }
                }
            }
            .tint(.primary)   // a list row, not a link: the system's own colour for a choice
            .swipeActions { if m.isHere { Button("Delete", role: .destructive) { deleting = m } } }
        }
        .alert(String(format: String(localized: "Download %@?"), asking?.title ?? ""), isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { m in
            Button("Download") { d.download(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in Text(sizeText(m.size)) }
        .alert(String(format: String(localized: "Delete %@?"), deleting?.title ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { m in
            Button("Delete", role: .destructive) { d.delete(m) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// Automatic, or a language by its name in the screen's language, sorted; Parakeet always detects, so the row is off
// with it (as on the Mac).
struct LanguagePicker: View {
    @State private var chosen = UserDefaults.standard.string(forKey: "language") ?? ""
    private var d: Dictation { Dictation.shared }
    var body: some View {
        let m = d.current ?? phoneModels.first { $0.id == d.modelID } ?? phoneModels[0]
        let here = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let named = m.languages.compactMap { c in here.localizedString(forLanguageCode: c).map { (c, $0.prefix(1).capitalized + $0.dropFirst()) } }
            .sorted { $0.1.compare($1.1, locale: here) == .orderedAscending }
        Picker("Language", selection: $chosen) {
            Text("Automatic").tag("")
            ForEach(named, id: \.0) { Text($0.1).tag($0.0) }
        }
        .disabled(m.languages.isEmpty)
        .onChange(of: chosen) { _, c in Store.shared.set(c.isEmpty ? nil : c, "language"); d.passSettings() }
    }
}

// Copy Text: as the Mac's Paste Text, a switch of this device only, on by default (the Mac always copies). Off, the
// text stays in the app until Send or a copy by hand (his word 2026-11-11: some want it only in the app).
struct CopyTextToggle: View {
    @AppStorage("copyText") private var on = true
    var body: some View { Toggle("Copy Text", isOn: $on) }
}

struct CopyTextFooter: View {
    var body: some View { Text("The text goes to the clipboard as soon as it is ready.") }
}

// How much history is kept: the same choices and words as the Mac's Settings window; synced like the language. A choice
// that would delete recordings asks once, with the number.
struct KeepPicker: View {
    static let choices: [(Keep, LocalizedStringKey)] = [(.all, "Keep All"), (.days(30), "30 Days"), (.days(7), "7 Days"),
                                                       (.last(100), "Last 100"), (.never, "Don’t Keep")]
    @State private var chosen = History.shared.keep.string
    @State private var asking: (raw: String, count: Int)?
    var body: some View {
        Picker("History", selection: Binding(get: { chosen }, set: { pick($0) })) {
            ForEach(KeepPicker.choices, id: \.0.string) { Text($0.1).tag($0.0.string) }
        }
        .confirmationDialog("Delete \(asking?.count ?? 0) recordings?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(asking?.count ?? 0) Recordings", role: .destructive) { if let a = asking { apply(a.raw) } }
        } message: { Text("These recordings will be deleted. This action cannot be undone.") }
    }
    private func pick(_ raw: String) {
        let gone = History.shared.wouldErase(Keep(raw))
        if gone > 0 { asking = (raw, gone) } else { apply(raw) }
    }
    private func apply(_ raw: String) {
        chosen = raw
        Store.shared.set(raw, Keep.key)
        History.shared.purge(); Shelf.shared.reload()
    }
}
