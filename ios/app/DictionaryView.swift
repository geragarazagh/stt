// The dictionary, as the Mac's window: Words (written exactly as here) and Replacements (Heard → Written), each with
// Restore for the built-in ones taken out. Synced with the person's other devices (store.swift).
// Made to work like Apple's own lists (his word 2026-11-11 16:24: he could not add «Vataga терминал»; ⌘V, ⌘C, ⌘A,
// selection, editing in the row, «+» to add and paste at once): every row is its own text field, edited where it
// stands; Add puts an empty row first, right under it, with the keyboard up; a list pasted into a row (one per line, or
// «heard<Tab>written», «heard → written») becomes as many rows; copying is the text field's own (select, Copy); a left swipe or Edit deletes. Saved as it changes.
import SwiftUI

struct DictionaryView: View {
    struct Word: Identifiable, Hashable { var id = UUID(); var text: String }
    struct Pair: Identifiable, Hashable { var id = UUID(); var heard: String; var written: String }
    enum Field: Hashable { case word(UUID), heard(UUID), written(UUID) }

    @State private var words = Words.words.map { Word(text: $0) }
    @State private var pairs = Words.replacements.map { Pair(heard: $0.heard, written: $0.written) }
    @FocusState private var focus: Field?
    private var d: Dictation { Dictation.shared }

    var body: some View {
        Form {
            Section {
                Button { addWord() } label: { Label("Add Word", systemImage: "plus") }
                ForEach($words) { $w in
                    // Several lines, so a pasted list keeps its line breaks (a one-line field turns them into spaces);
                    // Return at the end of a row still means «next word».
                    TextField("Word", text: $w.text, axis: .vertical)
                        .focused($focus, equals: .word(w.id))
                        .submitLabel(.next)
                        .onChange(of: w.text) { _, t in split(word: w.id, t) }
                }
                .onDelete { words.remove(atOffsets: $0); save() }
                if !Words.missingPreset.isEmpty { Button("Restore") { Words.restore(); reload() } }
            } header: { Text("Words") } footer: {
                Text(d.current?.id == "parakeet-ultra" ? "Parakeet doesn’t take a word list: only replacements work with it."
                                                       : "Names and terms written exactly as here.")
            }
            Section {
                Button { addPair() } label: { Label("Add Replacement", systemImage: "plus") }
                ForEach($pairs) { $p in
                    HStack {
                        TextField("Heard", text: $p.heard, axis: .vertical)
                            .focused($focus, equals: .heard(p.id))
                            .submitLabel(.next)
                            .onChange(of: p.heard) { _, t in split(pair: p.id, t) }
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        TextField("Written", text: $p.written)
                            .focused($focus, equals: .written(p.id))
                            .submitLabel(.done)
                            .onSubmit { savePairs() }
                    }
                }
                .onDelete { pairs.remove(atOffsets: $0); savePairs() }
                if !Words.missingPairs.isEmpty { Button("Restore") { Words.restorePairs(); reload() } }
            } header: { Text("Replacements") } footer: { Text("What a model writes, and what to write instead. For every model.") }
        }
        .navigationTitle("Dictionary")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .onChange(of: words) { save() }
        .onChange(of: pairs) { savePairs() }
        .onChange(of: focus) { _, f in if f == nil { tidy() } }
        .onReceive(NotificationCenter.default.publisher(for: Store.changedFromCloud)) { _ in if focus == nil { reload() } }
        .onDisappear { tidy() }
    }

    // The new row goes first, right under Add, so a long list needs no scrolling; an empty first row is reused, so
    // Return on an empty row stacks nothing. The keyboard comes once the row exists (a beat later).
    private func addWord() {
        if let first = words.first, first.text.trimmingCharacters(in: .whitespaces).isEmpty { focus = .word(first.id); return }
        let w = Word(text: ""); words.insert(w, at: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .word(w.id) }
    }
    private func addPair() {
        if let first = pairs.first, first.heard.isEmpty && first.written.isEmpty { focus = .heard(first.id); return }
        let p = Pair(heard: "", written: ""); pairs.insert(p, at: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .heard(p.id) }
    }

    private func parsePairs(_ t: String) -> [Pair] {
        var rows: [Pair] = []
        for line in t.components(separatedBy: .newlines) {
            for sep in ["\t", " → ", " -> ", " = "] where line.contains(sep) {
                let x = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
                if x.count == 2, !x[0].isEmpty, !x[1].isEmpty { rows.append(Pair(heard: x[0], written: x[1])) }
                break
            }
        }
        return rows
    }

    // A row's text with a line break or a comma: one line ending in Return is «next word»; a pasted list (several lines,
    // or commas) becomes a row for each.
    private func split(word id: UUID, _ t: String) {
        guard t.contains(where: { $0 == "\n" || $0 == "," }), let i = words.firstIndex(where: { $0.id == id }) else { return }
        let parts = t.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count <= 1 && t.hasSuffix("\n") {
            words[i].text = parts.first ?? ""
            addWord(); return
        }
        words.replaceSubrange(i...i, with: parts.map { Word(text: $0) })
        focus = nil
    }

    // A pasted list in a Heard field: lines «heard<Tab>written» (also « → », « -> », « = ») become rows.
    private func split(pair id: UUID, _ t: String) {
        guard t.contains(where: { $0 == "\n" || $0 == "\t" }) || t.contains(" → ") || t.contains(" -> "),
              let i = pairs.firstIndex(where: { $0.id == id }) else { return }
        // Return at the end of «Heard»: on to «Written».
        if t.hasSuffix("\n"), !t.dropLast().contains(where: { $0 == "\n" || $0 == "\t" }) {
            pairs[i].heard = String(t.dropLast()); focus = .written(id); return
        }
        let rows = parsePairs(t)
        guard !rows.isEmpty else { return }
        pairs.replaceSubrange(i...i, with: rows)
        focus = nil
    }

    // Empty rows go once nobody is typing in them.
    private func tidy() {
        words.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        pairs.removeAll { $0.heard.trimmingCharacters(in: .whitespaces).isEmpty && $0.written.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private func save() {
        Words.words = words.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        d.passSettings()
    }
    private func savePairs() {
        Words.replacements = pairs.map { ($0.heard.trimmingCharacters(in: .whitespaces), $0.written.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
        d.passSettings()
    }
    private func reload() {
        words = Words.words.map { Word(text: $0) }
        pairs = Words.replacements.map { Pair(heard: $0.heard, written: $0.written) }
        d.passSettings()
    }
}
