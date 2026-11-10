// Files: a small window of its own, apart from the settings, so the app doesn't look as if it existed only to take
// dropped files. Every way a person may try leads to it:
// - the «Choose File…» button in the main window's «Transcribe File» row: the system's file chooser at once (his choice
//   2026-11-10: the ellipsis promises a chooser, and somebody who changes their mind cancels it and nothing else opens);
//   the files window appears only once the work starts;
// - a drop anywhere on the main window;
// - this window's own shelf and its Choose File button (Command-O);
// - Finder's Open With (and a drop on STT.app in Finder): the files window opens and the work starts at once.
// A file's text goes to a .txt beside it, named after it, and onto the clipboard; it is never pasted, since nobody is
// typing anywhere when a file is done. The shelf says so before the drop, so nobody has to guess where the text went.
// Several files are taken one after another; files dropped during a job join it. What AVFoundation can't call audio or
// video is refused already while dragging.

import AppKit
import UniformTypeIdentifiers

// Audio and video by their type; an extension macOS doesn't know (a dynamic type) is let through and tried, AVFoundation
// decides. Measured: png, pdf, txt and a file with no extension refused; ogg, opus, amr, mkv, webm taken (mkv and webm then
// fail with «Can’t read sound from this file»: AVFoundation has no reader for them).
func mediaFiles(_ urls: [URL]) -> [URL] {
    urls.filter { url in
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return true }
        return type.conforms(to: .audiovisualContent) || type.isDynamic
    }
}

func draggedFiles(_ info: NSDraggingInfo) -> [URL] {
    mediaFiles(info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
}

// How round the system's own group box is, measured once by drawing one offscreen: the shelf takes its corner. The look
// changed in macOS 26 (on 27.2 a group box has a 10 pt corner), so a fixed number would be right on one system only.
@MainActor enum SystemShape {
    static let box: (rect: NSRect, radius: CGFloat) = {
        let b = NSBox()
        b.boxType = .primary
        b.titlePosition = .noTitle
        return measure(b, NSSize(width: 300, height: 180))
    }()

    private static func measure(_ view: NSView, _ size: NSSize) -> (rect: NSRect, radius: CGFloat) {
        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = holder.bounds
        holder.addSubview(view)
        holder.appearance = NSApp.effectiveAppearance
        guard let rep = holder.bitmapImageRepForCachingDisplay(in: holder.bounds) else { return (holder.bounds, 6) }
        holder.cacheDisplay(in: holder.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        let drawn = { (x: Int, y: Int) in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where drawn(x, y) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return (holder.bounds, 6) }
        // The corner: rows from the top edge until the left edge is reached; for a round corner that is its radius.
        var rows = 0
        while minY + rows <= maxY, !drawn(minX, minY + rows) { rows += 1 }
        let rect = NSRect(x: CGFloat(minX) / scale, y: size.height - CGFloat(maxY + 1) / scale,
                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return (rect, CGFloat(rows) / scale)
    }
}

// A dashed area that takes files: the big shelf of the files window.
class DropArea: NSView {
    var accepts: () -> Bool = { false }
    var dropped: ([URL]) -> Void = { _ in }
    var shape: (rect: NSRect, radius: CGFloat)? = nil   // nil: the whole view with the group box's corner
    var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let (rect, radius) = shape ?? (bounds, SystemShape.box.radius)
        // The dashed line runs inside the shape, so the shape's outer edge is where the system's own edge is.
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: max(radius - 0.75, 0), yRadius: max(radius - 0.75, 0))
        if hovering { NSColor.controlAccentColor.withAlphaComponent(0.1).setFill(); path.fill() }
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        (hovering ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard accepts(), !draggedFiles(info).isEmpty else { return [] }
        hovering = true
        return .copy
    }
    override func draggingExited(_ info: NSDraggingInfo?) { hovering = false }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        hovering = false
        let urls = draggedFiles(info)
        dropped(urls)
        return !urls.isEmpty
    }
}

// The main window takes a drop anywhere, since people drop on a window, not on a target. It lies over everything and lets
// clicks through; the copy cursor is the sign, as Finder gives it.
final class WindowDrop: NSView {
    var accepts: () -> Bool = { false }
    var dropped: ([URL]) -> Void = { _ in }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { accepts() && !draggedFiles(info).isEmpty ? .copy : [] }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let urls = draggedFiles(info)
        dropped(urls)
        return !urls.isEmpty
    }
}

@MainActor final class FilesWindow: NSObject {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    let area = DropArea(frame: NSRect(x: 20, y: 20, width: 300, height: 180))   // 20 pt from every edge and from the title bar
    private let symbol = NSImageView()
    private let line = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let choose = NSButton(title: "", target: nil, action: nil)
    private let reveal = NSButton(title: "", target: nil, action: nil)   // the written .txt; a click shows it in Finder
    private let bar = NSProgressIndicator()
    private let stop = NSButton(title: "", target: nil, action: nil)
    private var written: [URL] = []

    var hasModel: () -> Bool = { false }
    var beside: () -> NSWindow? = { nil }   // the main window, when it is open: the files window opens next to it
    var start: ([URL]) -> Void = { _ in }
    var cancel: () -> Void = {}

    override init() {
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let v = panel.contentView!
        v.addSubview(area)
        // A drop during a job joins it; only a missing model refuses one.
        area.accepts = { [weak self] in self?.hasModel() == true }
        area.dropped = { [weak self] in self?.start($0) }

        symbol.frame = NSRect(x: 126, y: 0, width: 48, height: 40)
        symbol.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        area.addSubview(symbol)
        for (l, size) in [(line, 13.0), (detail, 11.0)] {
            l.frame = NSRect(x: 12, y: 0, width: 276, height: 17)
            l.alignment = .center
            l.font = .systemFont(ofSize: CGFloat(size))
            l.lineBreakMode = .byTruncatingMiddle
            area.addSubview(l)
        }
        detail.textColor = .secondaryLabelColor

        choose.title = L("Choose File…")
        choose.bezelStyle = .rounded
        choose.sizeToFit()
        choose.frame.origin.x = (300 - choose.frame.width) / 2
        choose.target = self; choose.action = #selector(chooseFile)
        choose.refusesFirstResponder = true
        area.addSubview(choose)

        reveal.isBordered = false
        reveal.target = self; reveal.action = #selector(showInFinder)
        reveal.refusesFirstResponder = true
        reveal.toolTip = L("Show in Finder")
        area.addSubview(reveal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.frame = NSRect(x: 40, y: 0, width: 220, height: 12)
        area.addSubview(bar)

        stop.title = L("Cancel")
        stop.bezelStyle = .rounded
        stop.sizeToFit()
        stop.frame.origin.x = (300 - stop.frame.width) / 2
        stop.target = self; stop.action = #selector(stopClicked)
        stop.refusesFirstResponder = true
        area.addSubview(stop)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 && mods.isEmpty || e.keyCode == 13 && mods == .command { self.panel.performClose(nil); return nil }
            if e.keyCode == 31 && mods == .command, self.idle { self.chooseFile(); return nil }   // Command-O, as in every Mac app
            return e
        }
        showIdle()
    }

    private(set) var idle = true

    func show() {
        if idle { showIdle() }
        if !panel.isVisible { position() }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // Beside the main window, top edges level, right of it or else left of it; centred when the main window is closed
    // or neither side has room. Over the main window it would hide the row the person just clicked.
    private func position() {
        guard let main = beside(), main.isVisible, let screen = (main.screen ?? NSScreen.main)?.visibleFrame else { return panel.center() }
        let size = panel.frame.size, gap: CGFloat = 12, y = main.frame.maxY - size.height
        for x in [main.frame.maxX + gap, main.frame.minX - gap - size.width]
        where screen.contains(NSRect(x: x, y: y, width: size.width, height: size.height)) {
            return panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.center()
    }

    // Each state is laid out on its own, centred in the area.
    private func place(_ view: NSView, _ y: CGFloat) { view.isHidden = false; view.frame.origin.y = y }
    private func clear() { for view in [symbol, line, detail, choose, reveal, bar, stop] { view.isHidden = true } }

    // Before anything is dropped the shelf says what to do and what will come of it.
    func showIdle() {
        idle = true
        clear()
        symbol.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        place(symbol, 113)
        if hasModel() {
            line.stringValue = L("Drop audio or video here"); place(line, 88)
            detail.stringValue = L("The text is saved next to the file and copied"); place(detail, 68)
            place(choose, 27)
        } else {
            line.stringValue = L("No model chosen"); place(line, 80)
            detail.stringValue = L("Choose one in the STT window"); place(detail, 60)
        }
    }

    func showWork(_ name: String, _ share: Double, _ n: Int, _ count: Int) {
        idle = false
        clear()
        line.stringValue = name; place(line, 123)
        bar.doubleValue = share; place(bar, 101)
        let pct = "\(L("Transcribing…")) \(Int(share * 100))%"
        detail.stringValue = count > 1 ? "\(pct) · \(String(format: L("%1$d of %2$d"), n, count))" : pct
        place(detail, 75)
        place(stop, 34)
    }

    // Nothing is brought forward by itself: the .txt appears beside its file in Finder anyway, and its name here shows it.
    func showDone(_ written: [URL]) {
        idle = true
        self.written = written
        clear()
        symbol.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        place(symbol, 127)
        line.stringValue = L("Done"); place(line, 103)
        let name = written.count == 1 ? written[0].lastPathComponent : String(format: L("%d files"), written.count)
        reveal.attributedTitle = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.linkColor])
        reveal.sizeToFit()
        reveal.frame.size.width = min(reveal.frame.width, 276)
        (reveal.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        reveal.frame.origin.x = (300 - reveal.frame.width) / 2
        place(reveal, 79)
        detail.stringValue = L("The text is also on the clipboard"); place(detail, 59)
        place(choose, 17)
    }

    @objc func chooseFile() {
        guard hasModel() else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.audiovisualContent]
        p.prompt = L("Transcribe")
        p.beginSheetModal(for: panel) { [weak self] r in
            if r == .OK, !p.urls.isEmpty { self?.start(p.urls) }
        }
    }

    @objc func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(written) }

    @objc func stopClicked() { cancel() }
}
