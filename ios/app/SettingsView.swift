// Settings in the Mac window's order and words (stt.md, «How it works»): Model, Language; Dictionary; History: how much is
// kept (brief C). Transcribe File and Save Subtitles are the Mac's (his word 2026-11-11). What only a Mac has (keys, Open at Login, Pause Media, Mute Sound, Paste Text)
// is not here. A system sheet with a Form: on the iPhone Duo it moves and resizes by itself.
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var words = false
    @State private var keepPage = false   // Debug: the shots of the keep page
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
                Section { KeepRow() } footer: { Text("Texts and audio stay on this iPhone; the setting is the same on every device with this iCloud account.") }
                Section {} footer: { About() }
            }
            .navigationDestination(isPresented: $words) { DictionaryView() }
            #if DEBUG
            .onAppear { if Demo.sheet == "dictionary" { words = true }; if Demo.sheet == "keep" { keepPage = true } }
            .navigationDestination(isPresented: $keepPage) { KeepPage(keep: .constant(History.shared.keep), pick: { _ in }) }
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

// How much history is kept: the Mac's scale and words (KeepMenu), synced like the language. As in Settings > Messages
// > Keep Messages and Voice Memos' Clear Deleted, the row shows the choice and opens a page of the choices with a tick.
// A choice that would delete recordings asks once, with the number.
struct KeepRow: View {
    @State private var keep = History.shared.keep
    @State private var asking: (keep: Keep, count: Int)?
    var body: some View {
        NavigationLink { KeepPage(keep: $keep, pick: pick) } label: {
            LabeledContent("History") { Text(KeepRow.title(keep)) }
        }
        .confirmationDialog("Delete \(asking?.count ?? 0) recordings?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(asking?.count ?? 0) Recordings", role: .destructive) { if let a = asking { apply(a.keep) } }
        } message: { Text("These recordings will be deleted. This action cannot be undone.") }
    }
    static func title(_ k: Keep) -> String {
        if case .last(let n) = k { return String(localized: "Last \(n)") }
        return KeepMenu.scale.first { $0.0 == k }.map { String(localized: String.LocalizationValue($0.1)) } ?? ""
    }
    private func pick(_ k: Keep) {
        let gone = History.shared.wouldErase(k)
        if gone > 0 { asking = (k, gone) } else { apply(k) }
    }
    private func apply(_ k: Keep) {
        keep = k
        Store.shared.set(k.string, Keep.key)
        History.shared.purge(); Shelf.shared.reload()
    }
}

// The choices, a tick on the chosen one; a «Last N» set before 0.3 is listed last with its number while it holds.
struct KeepPage: View {
    @Binding var keep: Keep
    var pick: (Keep) -> Void
    var body: some View {
        List {
            Section {
                ForEach(KeepMenu.scale, id: \.0.string) { k, title in
                    row(Text(LocalizedStringKey(title)), on: keep == k) { pick(k) }
                }
                if case .last = keep { row(Text(KeepRow.title(keep)), on: true) {} }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func row(_ label: Text, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { label; Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) } }
        }
        .tint(.primary)   // black or white words, the tick in the accent colour, as Settings' own lists
    }
}
