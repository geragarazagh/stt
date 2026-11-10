// The dictionary (0.4): words a model should write as they are spelled here, and replacements a person writes for what
// a model keeps getting wrong. Measured 2026-11-10 on the author's 199 dictations: with only the built-in names 78 % of
// names came out right; names outside the list failed (Handy 7 of 13, GigaAM 0 of 4); with his own words in Whisper's
// prompt 80 %, exactly those words fixed (13 of 13, 4 of 4), nothing invented, the rest of the text unchanged.
// - Words go into Whisper's prompt and Qwen's system message. Parakeet takes no hints in this engine, which the window says.
// - Replacements («клод» → «Claude») work on the text of any model, after recognition. Only what a person wrote: guessing
//   sound-alikes from the word list fixed names but turned about 40 ordinary words into names («прочитай» → «Parakeet»).

import AppKit

// Names many people say and models spell wrongly unless they have seen them, each measured (Claude 0 → 16 of 16 on the
// author's dictations, nothing invented elsewhere). Order is priority: when the prompt is full the last ones stay out, and a
// person's own words go before these. Not longer on purpose: 42 names (Homebrew, Cloudflare, Spotify… added) made the
// author's dictations worse, 78 → 75 % of names right, since every extra name in Whisper's prompt weakens the others; a person's
// own words are what moves the number (Handy 7 → 13 of 13, GigaAM 0 → 4 of 4).
let presetWords = ["ChatGPT", "Claude", "Claude Code", "Anthropic", "OpenAI", "Gemini", "Google", "YouTube", "TikTok",
                   "Instagram", "Telegram", "WhatsApp", "Facebook", "GitHub", "iPhone", "macOS"]

// Stored as plain arrays under keys meant to stay as they are: STT for iPhone is to share the dictionary through iCloud
// both ways (the author's wish, 2026-11-10). The same three keys can go into NSUbiquitousKeyValueStore as they are; «changed»
// (the time of the last edit) settles which side wins when both changed, the later edit.
@MainActor enum Words {
    static let wordsKey = "words", replacementsKey = "replacements", changedKey = "dictionaryChanged"
    static var onChange: (() -> Void)?
    private static func changed() { UserDefaults.standard.set(Date(), forKey: changedKey); onChange?() }

    // Never edited: the preset. Edited: exactly what the person left, the preset ones they kept included.
    static var words: [String] {
        get { UserDefaults.standard.stringArray(forKey: wordsKey) ?? presetWords }
        set {
            let v = clean(newValue)
            guard v != words || UserDefaults.standard.stringArray(forKey: wordsKey) == nil && v != presetWords else { return }
            UserDefaults.standard.set(v, forKey: wordsKey); changed()
        }
    }

    static var replacements: [(heard: String, written: String)] {
        get { (UserDefaults.standard.array(forKey: replacementsKey) as? [[String]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
        set {
            let v = newValue.map { [$0.heard, $0.written] }
            guard v != replacements.map({ [$0.heard, $0.written] }) else { return }
            UserDefaults.standard.set(v, forKey: replacementsKey); changed()
        }
    }

    static var missingPreset: [String] {
        let have = Set(words.map { $0.lowercased() })
        return presetWords.filter { !have.contains($0.lowercased()) }
    }

    // The preset words that were removed come back where they were; the person's own words stay first.
    static func restore() { words = words + missingPreset }

    // Trimmed, no empty ones, no repeats (the first spelling wins).
    static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

// The person's replacements on finished text: the heard form as a whole word, any case; a Cyrillic one also with the
// Russian and Ukrainian case endings after it («клода», «клоду» → «Claude»), since a written name doesn't decline. Several
// words match with any spaces or hyphens between them. A sentence that began with the heard form keeps its capital.
func replace(_ text: String, _ pairs: [(heard: String, written: String)]) -> String {
    var s = text
    let ends = "(?:ами|ями|ові|еві|ом|ем|ой|ей|ах|ях|ам|ям|ов|ів|а|у|е|ы|и|і|ю|я|о)?"
    for (heard, written) in pairs.sorted(by: { $0.heard.count > $1.heard.count }) {
        let parts = heard.split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty, !written.isEmpty else { continue }
        let cyrillic = heard.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let pattern = "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "[\\s-]+") + (cyrillic ? ends : "") + "(?![\\p{L}\\p{N}])"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
        for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            var w = written
            if s[r].first?.isUppercase == true, w.first?.isLowercase == true {
                let before = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if before.isEmpty || ".?!…".contains(before.last!) { w = w.prefix(1).uppercased() + w.dropFirst() }
            }
            s.replaceSubrange(r, with: w)
        }
    }
    return s
}

// The dictionary's own small window, opened from the main window's «Dictionary» row. Words as tags (Return or a comma
// makes one, Delete removes it), «Restore» brings back removed preset words; under them the replacements as two columns,
// heard and written, with + and −, as macOS's own Text Replacements.
@MainActor final class DictionaryWindow: NSObject, NSTokenFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let panel: NSPanel
    let field = NSTokenField()
    let restore = NSButton(title: "", target: nil, action: nil)
    let note = NSTextField(wrappingLabelWithString: "")
    let table = NSTableView()
    let plusMinus = NSSegmentedControl()
    var rows: [[String]] = []
    var beside: (() -> NSWindow?)?
    var takesWords: (() -> Bool)?   // false for a model that ignores the list (Parakeet)

    override init() {
        let W: CGFloat = 420, H: CGFloat = 470, M: CGFloat = 20
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = L("Dictionary")
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let v = panel.contentView!

        func label(_ s: String, _ y: CGFloat, bold: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 11)
            l.textColor = bold ? .labelColor : .secondaryLabelColor
            l.frame = NSRect(x: M, y: y, width: W - 2 * M, height: bold ? 18 : 28)
            v.addSubview(l)
            return l
        }
        _ = label(L("Words"), H - 38, bold: true)
        _ = label(L("Names and terms written exactly as here. Return adds a word."), H - 70)
        let scroll = NSScrollView(frame: NSRect(x: M, y: H - 196, width: W - 2 * M, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        field.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 120)
        field.autoresizingMask = [.width]
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        field.tokenStyle = .rounded
        field.isBordered = false
        field.delegate = self
        field.target = self; field.action = #selector(wordsEdited)
        (field.cell as? NSTokenFieldCell)?.wraps = true
        scroll.documentView = field
        v.addSubview(scroll)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: M, y: H - 236, width: W - 2 * M - 120, height: 32)
        v.addSubview(note)
        restore.title = L("Restore")
        restore.bezelStyle = .rounded
        restore.controlSize = .small
        restore.target = self; restore.action = #selector(restorePreset)
        restore.sizeToFit()
        restore.frame.origin = NSPoint(x: W - M - restore.frame.width, y: H - 226)
        v.addSubview(restore)

        _ = label(L("Replacements"), H - 268, bold: true)
        _ = label(L("What a model writes, and what to write instead. For every model."), H - 300)
        for (id, title) in [("heard", L("Heard")), ("written", L("Written"))] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = (W - 2 * M - 20) / 2
            table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let tableScroll = NSScrollView(frame: NSRect(x: M, y: 48, width: W - 2 * M, height: H - 300 - 54))
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = table
        v.addSubview(tableScroll)
        plusMinus.segmentCount = 2
        plusMinus.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        plusMinus.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        plusMinus.trackingMode = .momentary
        plusMinus.segmentStyle = .smallSquare
        plusMinus.target = self; plusMinus.action = #selector(plusMinusClicked)
        plusMinus.frame = NSRect(x: M, y: 24, width: 48, height: 24)
        v.addSubview(plusMinus)
    }

    // The field grows with its tags and the scroll view around it scrolls; a fixed field hid the words past its end.
    func fitField() {
        let w = field.frame.width
        field.preferredMaxLayoutWidth = w
        let cell = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 100_000)).height ?? 0
        // Both measures came out a line or two short of the drawn tags on macOS 26 (the last row was cut): a line more.
        field.frame.size.height = max(120, ceil(max(cell, field.intrinsicContentSize.height)) + 24)
    }
    // The end of the list in view, where a new word goes.
    func scrollToEnd() {
        guard let sv = field.enclosingScrollView else { return }
        let y = field.isFlipped ? max(0, field.frame.height - sv.contentSize.height) : 0
        sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
    }
    // Saved at every change, so a word works in the next dictation without closing the window.
    func controlTextDidChange(_ n: Notification) {
        guard (n.object as? NSTokenField) === field else { return }
        fitField(); scrollToEnd(); wordsEdited()
    }

    func show() {
        field.objectValue = Words.words
        fitField()
        rows = Words.replacements.map { [$0.heard, $0.written] }
        table.reloadData()
        refresh()
        if !panel.isVisible, let main = beside?() {
            let f = main.frame, s = main.screen?.visibleFrame ?? f
            var x = f.maxX + 12
            if x + panel.frame.width > s.maxX { x = f.midX - panel.frame.width / 2 }
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: f.maxY))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        // Ready to type at the end of the list, nothing selected (the field selects all its tags when it takes focus).
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0) }
        scrollToEnd()
    }

    func refresh() {
        restore.isEnabled = !Words.missingPreset.isEmpty
        note.stringValue = takesWords?() == false ? L("Parakeet doesn’t take a word list: only replacements work with it.") : ""
    }

    @objc func wordsEdited() {
        Words.words = (field.objectValue as? [String]) ?? []
        refresh()
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField, f !== field else { wordsEdited(); return }
        let row = table.row(for: f), column = table.column(for: f)
        guard row >= 0, row < rows.count, column >= 0 else { return }
        rows[row][column] = f.stringValue
        saveRows()
    }

    // Tab in the first column goes on to the second one of the same row, as in macOS's Text Replacements.
    func control(_ c: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard c !== field, selector == #selector(NSResponder.insertTab(_:)), table.column(for: c) == 0 else { return false }
        let row = table.row(for: c)
        if let f = c as? NSTextField, row >= 0, row < rows.count { rows[row][0] = f.stringValue }
        DispatchQueue.main.async { self.table.editColumn(1, row: row, with: nil, select: true) }
        return true
    }
    func windowWillClose(_ n: Notification) { panel.makeFirstResponder(nil); wordsEdited(); saveRows() }

    @objc func restorePreset() {
        wordsEdited()
        Words.restore()
        field.objectValue = Words.words
        fitField()
        refresh()
    }

    @objc func plusMinusClicked() {
        if plusMinus.selectedSegment == 0 {
            panel.makeFirstResponder(nil)
            rows.append(["", ""])
            table.reloadData()
            table.editColumn(0, row: rows.count - 1, with: nil, select: true)
        } else if table.selectedRow >= 0 {
            panel.makeFirstResponder(nil)
            rows.remove(at: table.selectedRow)
            table.reloadData()
            saveRows()
        }
    }

    func saveRows() {
        Words.replacements = rows.map { ($0[0].trimmingCharacters(in: .whitespaces), $0[1].trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(string: rows[row][c?.identifier.rawValue == "heard" ? 0 : 1])
        f.isBordered = false
        f.drawsBackground = false
        f.isEditable = true
        f.lineBreakMode = .byTruncatingTail
        f.delegate = self
        return f
    }
}
