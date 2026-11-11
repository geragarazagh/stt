// The dictionary's window on the Mac (the words and pairs themselves: shared/dictionary.swift).

import AppKit

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
    let restorePairs = NSButton(title: "", target: nil, action: nil)
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
        // The built-in pairs that were removed, back: the same small button as under the words, level with + and −.
        restorePairs.title = L("Restore")
        restorePairs.bezelStyle = .rounded
        restorePairs.controlSize = .small
        restorePairs.target = self; restorePairs.action = #selector(restoreBuiltInPairs)
        restorePairs.sizeToFit()
        restorePairs.frame.origin = NSPoint(x: W - M - restorePairs.frame.width, y: 24 + (24 - restorePairs.frame.height) / 2)
        v.addSubview(restorePairs)
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
        reload()
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

    // What is stored now: at opening, and when another device of the person's changed the dictionary (store.swift). Not in
    // the middle of a person's typing here: that would lose a row being written; it comes once the edit ends, and the edit,
    // being the later one, is what both devices keep.
    var reloadAfterEdit = false
    func reload(elsewhere: Bool = false) {
        if elsewhere, panel.isVisible, panel.firstResponder is NSTextView { reloadAfterEdit = true; return }
        reloadAfterEdit = false
        field.objectValue = Words.words
        fitField()
        rows = Words.replacements.map { [$0.heard, $0.written] }
        table.reloadData()
        refresh()
    }

    func refresh() {
        restore.isEnabled = !Words.missingPreset.isEmpty
        restorePairs.isEnabled = !Words.missingPairs.isEmpty
        note.stringValue = takesWords?() == false ? L("Parakeet doesn’t take a word list: only replacements work with it.") : ""
    }

    @objc func wordsEdited() {
        Words.words = (field.objectValue as? [String]) ?? []
        refresh()
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField, f !== field else {
            wordsEdited()
            if reloadAfterEdit { DispatchQueue.main.async { self.reload() } }
            return
        }
        let row = table.row(for: f), column = table.column(for: f)
        guard row >= 0, row < rows.count, column >= 0 else { return }
        rows[row][column] = f.stringValue
        saveRows()
        if reloadAfterEdit { DispatchQueue.main.async { self.reload() } }
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

    @objc func restoreBuiltInPairs() {
        panel.makeFirstResponder(nil)
        saveRows()
        Words.restorePairs()
        rows = Words.replacements.map { [$0.heard, $0.written] }
        table.reloadData()
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
        refresh()
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
