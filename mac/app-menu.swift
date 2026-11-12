// The app's side of history and of the main window: the menu bar it has while the window is open, the keep setting,
// the recording shown under the list, transcribing again. The window itself: main-window.swift; the store:
// shared/history.swift.
import AppKit
import AVFoundation

extension App {
    func setUpShelf() {
        let shelf = Shelf.shared
        shelf.record = { [weak self] in self?.pressed() }
        shelf.cancel = { [weak self] in self?.cancel() }
        shelf.settings = { [weak self] in self?.window?.show() }
        shelf.again = { [weak self] r, m in self?.again(r, with: m) }
        shelf.hotKey = { [weak self] in self?.window?.keyButton.title ?? "" }
        buildMenu()
    }

    @objc func showMain() {
        if main == nil {
            let m = MainWindow()
            // Closed: back to the background, as STT was before, unless the Settings window is still open.
            m.closed = { [weak self] in
                DispatchQueue.main.async { if self?.window?.panel.isVisible != true { NSApp.setActivationPolicy(.accessory) } }
            }
            main = m
        }
        main?.show()
    }

    @objc func showSettings() { window?.show() }

    // The wave and the clock under the list follow the microphone, 20 times a second, as the iPhone's card.
    func showRecording() {
        let s = Shelf.shared
        s.started = Date(); s.stopped = nil; s.wave = []; s.phase = .recording
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recording else { return }
                Shelf.shared.wave.append(self.recorder.level())
            }
        }
    }

    // MARK: keep

    static let keeps: [(Keep, String)] = [(.all, "Keep All"), (.days(30), "30 Days"), (.days(7), "7 Days"),
                                          (.last(100), "Last 100"), (.never, "Don’t Keep")]

    func rebuildKeep() {
        keepPicker.removeAllItems()
        for (k, title) in App.keeps {
            keepPicker.addItem(withTitle: L(title))
            keepPicker.lastItem?.representedObject = k.string
        }
        let now = History.shared.keep
        keepPicker.selectItem(at: App.keeps.firstIndex { $0.0 == now } ?? 0)
    }

    // A choice that would throw recordings away asks once, with the number.
    @objc func pickedKeep() {
        guard let raw = keepPicker.selectedItem?.representedObject as? String else { return }
        let new = Keep(raw)
        let gone = History.shared.wouldErase(new)
        if gone > 0 {
            let a = NSAlert()
            a.messageText = String(format: L("Delete %d recordings?"), gone)
            a.informativeText = L("These recordings will be deleted. This action cannot be undone.")
            a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
            a.addButton(withTitle: L("Cancel"))
            if a.runModal() != .alertFirstButtonReturn { rebuildKeep(); return }
        }
        Store.shared.set(raw, Keep.key)
        History.shared.purge()
        Shelf.shared.reload()
    }

    // MARK: transcribe again

    // With any downloaded model: it is loaded for this one job and the chosen one comes back after; the text is replaced
    // and the record says which model made it.
    func again(_ r: Recording, with m: ASRModel) {
        guard let u = r.audioURL, !recording, !stopping, let back = current else { return }
        let id = r.objectID
        Shelf.shared.busy.insert(id)
        let engine = self.engine
        engine.queue.async {
            let result = Result { () -> String in
                let pcm = try readMedia(u)
                if m.id != back.id { try engine.load(path: m.path.path) }
                defer { if m.id != back.id { try? engine.load(path: back.path.path) } }
                return try engine.transcribe(pcm)
            }
            DispatchQueue.main.async {
                Shelf.shared.busy.remove(id)
                switch result {
                case .success(let text) where !text.isEmpty:
                    History.shared.edit(r, text: text); r.model = m.id; r.edited = nil
                    try? r.managedObjectContext?.save()
                case .success: report(L("Transcription failed"), L("No speech found"))
                case .failure(let e): report(L("Transcription failed"), "\(e)")
                }
            }
        }
    }

    // MARK: menu bar

    // What a person finds in the menu bar while the main window is open: Voice Memos' menus, as far as STT has things
    // to put in them.
    func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: ""); host.submenu = m; bar.addItem(host)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, _ target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.target = target
            return i
        }
        let updates = item(L("Check for Updates…"), #selector(Updates.check), "", [], Updates.shared)
        _ = menu("STT", [item(L("Settings…"), #selector(showSettings), ",", .command, self), updates, .separator(),
                         item(L("Hide STT"), #selector(NSApplication.hide(_:)), "h"),
                         item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                         item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                         item(L("Quit STT"), #selector(NSApplication.terminate(_:)), "q")])
        _ = menu(L("File"), [item(L("New Recording"), #selector(newRecording), "n", .command, self),
                             item(L("Transcribe File…"), #selector(chooseFiles), "o", .command, self), .separator(),
                             item(L("Close"), #selector(NSWindow.performClose(_:)), "w")])
        _ = menu(L("Edit"), [item(L("Undo"), Selector(("undo:")), "z"), item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]), .separator(),
                             item(L("Cut"), #selector(NSText.cut(_:)), "x"), item(L("Copy"), #selector(NSText.copy(_:)), "c"),
                             item(L("Paste"), #selector(NSText.paste(_:)), "v"), item(L("Delete"), #selector(NSText.delete(_:))),
                             item(L("Select All"), #selector(NSText.selectAll(_:)), "a"), .separator(),
                             item(L("Find"), #selector(NSResponder.performTextFinderAction(_:)), "f")])
        _ = menu(L("View"), [item(L("Show Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])])
        let win = menu(L("Window"), [item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
                                     item(L("Zoom"), #selector(NSWindow.performZoom(_:))), .separator(),
                                     item("STT", #selector(showMain), "0", .command, self)])
        NSApp.mainMenu = bar
        NSApp.windowsMenu = win
    }

    // The test copy only (bundle id …stt.test, build TEST=1): a theme and a state for the shots shown to him, from the
    // environment. The real app never reads these.
    func demo() {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".test") == true else { return }
        let env = ProcessInfo.processInfo.environment
        if let a = env["STT_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        // A picture of every window drawn by the app itself, for test machines where screencapture sees only the
        // wallpaper over ssh (macOS 13).
        if let dir = env["STT_SNAP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                for (i, w) in NSApp.windows.filter(\.isVisible).enumerated() {
                    guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/w\(i).png"))
                    // What the toolbar holds, since a drawing of the window leaves the toolbar out on some systems.
                    let items = (w.toolbar?.items ?? []).map { "\($0.itemIdentifier.rawValue) \($0.label) visible=\(w.toolbar?.visibleItems?.contains($0) == true)" }
                    try? (["\(w.title) \(Int(w.frame.width))x\(Int(w.frame.height))"] + items).joined(separator: "\n").write(toFile: "\(dir)/w\(i).txt", atomically: true, encoding: .utf8)
                }
            }
        }
        let s = Shelf.shared
        switch env["STT_DEMO"] {
        case "recording", "transcribing":
            s.started = Date().addingTimeInterval(-4.71); s.phase = .recording
            var x: UInt64 = 7
            s.wave = (0..<94).map { i in
                x = x &* 6364136223846793005 &+ 1442695040888963407
                let r = Float(x >> 40) / Float(1 << 24), word = sin(Float(i) / 2.3) * 0.5 + 0.5
                return min(1, (0.12 + 0.5 * word + 0.38 * r) * ((i / 17) % 5 == 4 ? 0.05 : 1))
            }
            if env["STT_DEMO"] == "transcribing" { s.stopped = Date(); s.phase = .transcribing }
            else {
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    MainActor.assumeIsolated { if s.phase == .recording { s.wave.append(Float.random(in: 0.1...0.9)) } }
                }
            }
        case "settings": window?.show()
        case "dictionary": window?.show(); showDictionary()
        case "select": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { s.demoSelection = 3 }
        case "confirm": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { s.folder = .deleted; s.demoAsk = true; s.demoSelection = 2 }
        case "deleted": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { s.folder = .deleted; s.demoSelection = 1 }
        default: break
        }
    }

    // ⌘N, as Voice Memos' New Recording: the same as the key.
    @objc func newRecording() { pressed() }
}
