// STT, speech to text: a hot key starts recording, the same key stops it, and the text lands in the app in front.
// Offline: the only network call is downloading a model the user chose. No logs, no history.
//
// Test the whole pipeline without microphone or clipboard (quit the app first, a hot key has one owner):
//   STT.app/Contents/MacOS/STT --file some.wav [model file name]
//
// Why it is built this way:
// - Engine: transcribe.cpp (MIT, vendor/ and Contents/Frameworks), the one Handy runs on since 2026: one API over
//   Whisper, Parakeet and Qwen, each model a single .gguf file. A prebuilt framework, so no Xcode is needed.
// - Long speech is cut at pauses into pieces of about 30 s, because most models lose accuracy past 30-40 s in one run,
//   and silence is thrown out, because Whisper invents text on silence («Субтитры сделал...»).
// - The text stays on the clipboard after pasting: if the paste misses, nothing is lost.
// - Feedback while recording is macOS's own orange microphone dot; nothing of ours appears on screen.
// - No model comes with the app. Each one downloads only after a person agrees to its size, and nothing is asked before
//   that: microphone, then Accessibility, one at a time, once a model is there.

import AppKit
import AVFoundation
import Carbon.HIToolbox

// MARK: models

struct ASRModel {
    let id: String, title: String, languages: [String], file: String, revision: String, sha256: String, size: Int64
    var url: URL { URL(string: "https://huggingface.co/handy-computer/\(id)-gguf/resolve/\(revision)/\(file)")! }
    var path: URL { modelsFolder.appendingPathComponent(file) }
    var isHere: Bool { FileManager.default.fileExists(atPath: path.path) }
}

func sizeText(_ bytes: Int64) -> String {
    (bytes / 1_000_000).formatted(.number.locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"))) + " " + L("MB")
}

// The best model of each maker for dictation, named in plain words, biggest first: what a person
// sees is the name, the size and whether it is here. Language codes are the models' own general.languages.
let models: [ASRModel] = [
    ASRModel(id: "Qwen3-ASR-1.7B", title: "Qwen",
             languages: "zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el ro hu mk".split(separator: " ").map(String.init),
             file: "Qwen3-ASR-1.7B-Q8_0.gguf",
             revision: "92282af1610a2db19d66f2bef1e260f5deca782d",
             sha256: "9a0d81792dfea2d5f278b8a63deb3ea6e02139ce42c2301f32ea19c4f77526b7", size: 2185030624),
    ASRModel(id: "whisper-large-v3-turbo", title: "Whisper",
             languages: "af am ar as az ba be bg bn bo br bs ca cs cy da de el en es et eu fa fi fo fr gl gu haw ha he hi hr ht hu hy id is it ja jw ka kk km kn ko la lb ln lo lt lv mg mi mk ml mn mr ms mt my ne nl nn no oc pa pl ps pt ro ru sa sd si sk sl sn so sq sr su sv sw ta te tg th tk tl tr tt uk ur uz vi yi yo yue zh".split(separator: " ").map(String.init),
             file: "whisper-large-v3-turbo-Q8_0.gguf",
             revision: "5eaf945c7978e564bae5b28a5b1639dd93c2bfb1",
             sha256: "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183", size: 886381760),
    ASRModel(id: "parakeet-ultra", title: "Parakeet",
             languages: [],   // it takes a language hint and ignores it: wrong hints changed nothing in 5 of 5 tests, it always detects
             file: "parakeet-ultra-Q8_0.gguf",
             revision: "39eeb55181f0d354fd934f06e92fd8d5037fed8e",
             sha256: "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59", size: 740363168),
]

// ~/Library/Application Support/STT/models: plain files, easy to find and to delete by hand. It appears only with the first
// download and goes with the last delete. The name comes from the bundle so a test build keeps to its own folder.
let appFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "STT", isDirectory: true)
let modelsFolder = appFolder.appendingPathComponent("models", isDirectory: true)

// MARK: microphone

// A new engine for every recording: it picks up whatever input device is the system default right now.
final class Recorder {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let from = input.outputFormat(forBus: 0)
        guard from.sampleRate > 0, let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to) else { throw NSError(domain: "No audio input", code: 1) }
        samples = []
        input.installTap(onBus: 0, bufferSize: 2048, format: from) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / from.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: capacity) else { return }
            var given = false
            converter.convert(to: out, error: nil) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return buffer
            }
            guard let self, let c = out.floatChannelData?[0] else { return }
            self.lock.lock(); self.samples.append(contentsOf: UnsafeBufferPointer(start: c, count: Int(out.frameLength))); self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

// MARK: hot key

// A session event tap, the way Handy does it. It runs ahead of macOS's own shortcuts: Option-Command-Space belongs
// to macOS by default and RegisterEventHotKey never hears it, while the tap takes it with nothing switched off in
// System Settings. It needs Accessibility, which pasting needs anyway. Without it the Carbon key of AppWindow still works.
private var tapPort: CFMachPort?
private var tapHandler: ((_ key: Int, _ mods: Int, _ down: Bool, _ repeated: Bool) -> Bool)?

func startKeyTap(_ handler: @escaping (Int, Int, Bool, Bool) -> Bool) -> Bool {
    tapHandler = handler
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let f = event.flags
        var mods = 0
        if f.contains(.maskCommand) { mods |= cmdKey }
        if f.contains(.maskAlternate) { mods |= optionKey }
        if f.contains(.maskControl) { mods |= controlKey }
        if f.contains(.maskShift) { mods |= shiftKey }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        return tapHandler?(key, mods, type == .keyDown, repeated) == true ? nil : Unmanaged.passUnretained(event)
    }, userInfo: nil) else { return false }
    tapPort = port
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    return true
}

// MARK: app

@MainActor final class App: NSObject, NSApplicationDelegate {
    let pasteboard: NSPasteboard
    let engine = Engine()
    let recorder = Recorder()
    let mute = Mute()
    let media = Media()
    var recording = false
    var pressedAt: Date?
    var window: AppWindow?
    let picker = NSPopUpButton(frame: .zero)
    let languagePicker = NSPopUpButton(frame: .zero)
    let note = NSTextField(labelWithString: "")
    let stopDownload = NSButton(title: "", target: nil, action: nil)
    var download: Download?
    var downloading: ASRModel?
    var asked = false

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var current: ASRModel? {
        models.first { $0.id == UserDefaults.standard.string(forKey: "model") && $0.isHere }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        mute.recoverAfterCrash()
        // A .part file lives only while the app runs; a crash can leave one behind.
        for m in models { try? FileManager.default.removeItem(at: m.path.appendingPathExtension("part")) }
        window = AppWindow(name: "STT", github: "https://github.com/geragarazagh/stt",
                           defaultShortcut: Shortcut(key: kVK_Space, mods: cmdKey | optionKey),
                           defaultCancel: Shortcut(key: kVK_Escape, mods: cmdKey), extra: settingsRows(),
                           release: { [weak self] in self?.released() }) { [weak self] in self?.pressed() }
        if let content = window?.panel.contentView {
            let drop = DropView(frame: content.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.registerForDraggedTypes([.fileURL])
            drop.accepts = { [weak self] in self?.current != nil && self?.fileJob == nil }
            drop.dropped = { [weak self] in self?.transcribeFiles($0) }
            content.addSubview(drop)
        }
        rebuildMenu()
        if let m = current { load(m) } else { window?.show() }
        if AXIsProcessTrusted() { tryTap() }
    }

    // One question at a time: two system dialogs at once land on top of each other.
    func askPermissions() {
        guard !asked else { return }
        asked = true
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                if !AXIsProcessTrusted() {
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
                self.tryTap()
            }
        }
    }

    // Accessibility can be granted at any moment after launch, and macOS tells nobody.
    func tryTap() {
        guard window?.tapOwnsKeys == false else { return }
        // The check comes first: asking for a tap without the grant can raise a dialog of its own.
        let ok = AXIsProcessTrusted() && startKeyTap { [weak self] key, mods, down, repeated in
            MainActor.assumeIsolated { self?.keyEvent(key, mods, down, repeated) ?? false }
        }
        if ok {
            window?.tapOwnsKeys = true
            window?.unregister()
            window?.refresh()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.tryTap() }
        }
    }

    var swallowUp = -1

    // Starting the microphone takes a while, and every key press on the Mac waits for a tap to return: a slow one
    // delays typing everywhere and macOS can switch the tap off. So the work happens after the tap has answered.
    func later(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    // True takes the key away from everyone else.
    func keyEvent(_ key: Int, _ mods: Int, _ down: Bool, _ repeated: Bool) -> Bool {
        guard let window else { return false }
        if !down {
            guard key == swallowUp else { return false }
            swallowUp = -1
            if key == window.shortcut.key { later { self.released() } }
            return true
        }
        if window.recording, window.panel.isKeyWindow {
            window.recorded(key: key, mods: mods)
            swallowUp = key
            return true
        }
        if key == window.shortcut.key && mods == window.shortcut.mods {
            if !repeated { later { self.pressed() } }
            swallowUp = key
            return true
        }
        if recording, let c = window.cancelKey, key == c.key && mods == c.mods {
            later { self.cancel() }
            swallowUp = key
            return true
        }
        return false
    }

    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.show()
        return false
    }

    func applicationWillTerminate(_ n: Notification) {
        if recording { _ = recorder.stop(); soundBack() }
        download?.cancel()
        for m in models { try? FileManager.default.removeItem(at: m.path.appendingPathExtension("part")) }
        engine.queue.sync { engine.release() }
    }

    // MARK: settings

    func settingsRows() -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 92 + 3 * 30))
        func label(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13)
            l.frame = NSRect(x: 20, y: y, width: 240, height: 18)
            row.addSubview(l)
        }
        func toggle(_ s: String, _ key: String, _ standard: Bool, _ y: CGFloat) {
            label(s, y + 1)
            let t = NSSwitch()
            t.controlSize = .small
            t.sizeToFit()
            t.frame.origin = NSPoint(x: 340 - 20 - t.frame.width + 5, y: y)   // the switch draws 5 pt inside its frame
            t.identifier = NSUserInterfaceItemIdentifier(key)
            t.state = UserDefaults.standard.object(forKey: key) as? Bool ?? standard ? .on : .off
            t.target = self; t.action = #selector(switched(_:))
            t.refusesFirstResponder = true
            row.addSubview(t)
        }
        toggle(L("Paste Text"), "paste", true, 66)
        toggle(L("Mute Sound"), "mute", false, 36)
        toggle(L("Pause Media"), "pauseMedia", false, 6)

        label(L("Language"), 119)
        languagePicker.frame = NSRect(x: 340 - 20 - 216, y: 114, width: 220, height: 26)
        languagePicker.target = self; languagePicker.action = #selector(pickedLanguage)
        languagePicker.refusesFirstResponder = true
        row.addSubview(languagePicker)
        label(L("Model"), 149)
        picker.frame = NSRect(x: 340 - 20 - 216, y: 144, width: 220, height: 26)
        picker.target = self; picker.action = #selector(picked)
        picker.refusesFirstResponder = true
        row.addSubview(picker)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .right
        note.frame = NSRect(x: 20, y: 96, width: 300, height: 14)
        row.addSubview(note)
        stopDownload.title = L("Cancel")
        stopDownload.bezelStyle = .rounded
        stopDownload.controlSize = .small
        stopDownload.font = .systemFont(ofSize: 11)
        stopDownload.sizeToFit()
        stopDownload.frame.origin = NSPoint(x: 20, y: 92)
        stopDownload.target = self; stopDownload.action = #selector(cancelDownload)
        stopDownload.refusesFirstResponder = true
        stopDownload.isHidden = true
        row.addSubview(stopDownload)
        return row
    }

    @objc func switched(_ t: NSSwitch) {
        if let key = t.identifier?.rawValue { UserDefaults.standard.set(t.state == .on, forKey: key) }
    }

    func isOn(_ key: String, _ standard: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? standard
    }

    // The list: each model with what a person needs to choose it. Then the folder, and the delete for the one in use.
    func rebuildMenu() {
        picker.removeAllItems()
        let shown = downloading ?? current
        if shown == nil {
            picker.addItem(withTitle: L("Choose a Model"))
        }
        for m in models {
            picker.addItem(withTitle: m.title)
            picker.lastItem?.representedObject = m.id
            // NSMenuItem.subtitle starts at macOS 14.4; this draws the same on every system.
            let line = [sizeText(m.size), m.isHere ? L("Downloaded") : nil].compactMap { $0 }.joined(separator: " · ")
            let text = NSMutableAttributedString(string: m.title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
            text.append(NSAttributedString(string: "\n" + line, attributes: [.font: NSFont.menuFont(ofSize: 11)]))
            picker.lastItem?.attributedTitle = text
        }
        picker.menu?.addItem(.separator())
        if FileManager.default.fileExists(atPath: modelsFolder.path) {
            picker.addItem(withTitle: L("Show in Finder"))
            picker.lastItem?.action = #selector(showFolder)
            picker.lastItem?.target = self
        }
        for (i, m) in models.enumerated() where m.isHere {
            picker.addItem(withTitle: String(format: L("Delete %@…"), m.title))
            picker.lastItem?.tag = i
            picker.lastItem?.action = #selector(deleteModel(_:))
            picker.lastItem?.target = self
        }
        if picker.menu?.items.last?.isSeparatorItem == true { picker.menu?.removeItem(picker.menu!.items.last!) }
        if let shown { picker.selectItem(at: picker.indexOfItem(withRepresentedObject: shown.id)) } else { picker.selectItem(at: 0) }
        // The closed button shows the name alone, not the menu's two lines.
        let cell = picker.cell as? NSPopUpButtonCell
        cell?.usesItemFromMenu = false
        cell?.menuItem = NSMenuItem(title: shown?.title ?? L("Choose a Model"), action: nil, keyEquivalent: "")
        rebuildLanguages()
        note.placeholderAttributedString = current == nil ? nil : NSAttributedString(string: L("Drop audio or video here"),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }

    // Automatic, then the languages of the model in use by name, in the language of the window. A choice the model can't
    // take stays stored and counts as Automatic, so going back to the other model brings it back.
    func rebuildLanguages() {
        languagePicker.removeAllItems()
        languagePicker.addItem(withTitle: L("Automatic"))
        languagePicker.isEnabled = current?.languages.isEmpty == false
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let named: [(code: String, name: String)] = (current?.languages ?? []).compactMap { (code: String) -> (code: String, name: String)? in
            // Whisper's own code for Javanese is jw; the standard one is jv.
            guard let n = locale.localizedString(forLanguageCode: code == "jw" ? "jv" : code) else { return nil }
            return (code, n.prefix(1).uppercased(with: locale) + n.dropFirst())
        }
        for l in named.sorted(by: { $0.name.compare($1.name, locale: locale) == .orderedAscending }) {
            languagePicker.addItem(withTitle: l.name)
            languagePicker.lastItem?.representedObject = l.code
        }
        let chosen = UserDefaults.standard.string(forKey: "language")
        let index = chosen.map { languagePicker.indexOfItem(withRepresentedObject: $0) } ?? -1
        languagePicker.selectItem(at: max(index, 0))
        let code = languagePicker.selectedItem?.representedObject as? String
        let engine = self.engine
        engine.queue.async { engine.forced = code }
    }

    @objc func pickedLanguage() {
        UserDefaults.standard.set(languagePicker.selectedItem?.representedObject as? String, forKey: "language")
        rebuildLanguages()
    }

    @objc func picked() {
        guard let id = picker.selectedItem?.representedObject as? String, let m = models.first(where: { $0.id == id }) else { return }
        guard m.id != current?.id || downloading != nil else { return }
        if m.isHere {
            UserDefaults.standard.set(m.id, forKey: "model")
            stopFetching()
            rebuildMenu()
            load(m)
        } else if m.id != downloading?.id {
            confirmDownload(m)
        }
    }

    func alert(_ title: String, _ text: String, _ buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal()
    }

    // The size is the whole point of asking: on mobile internet a gigabyte is a person's money.
    func confirmDownload(_ m: ASRModel) {
        defer { rebuildMenu() }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        if free < m.size + 100_000_000 {
            _ = alert(L("Not enough disk space"), String(format: L("%1$@ needs %2$@. Free: %3$@."), m.title, sizeText(m.size), sizeText(free)), ["OK"])
            return
        }
        let answer = alert(String(format: L("Download %@?"), m.title), sizeText(m.size), [L("Download"), L("Cancel")])
        if answer == .alertFirstButtonReturn { fetch(m) }
    }

    func fetch(_ m: ASRModel) {
        stopFetching()
        do { try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true) }
        catch { report("STT: \(m.title)", "\(error)"); return }
        downloading = m
        note.stringValue = L("Downloading…")
        stopDownload.isHidden = false
        let d = Download(url: m.url, target: m.path, sha: m.sha256, size: m.size, progress: { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.downloading?.id == m.id else { return }
                self.note.stringValue = "\(L("Downloading…")) \(Int(p * 100))%"
            }
        }, done: { [weak self] failure in
            DispatchQueue.main.async {
                guard let self, self.downloading?.id == m.id else { return }
                self.download = nil; self.downloading = nil
                self.note.stringValue = ""
                self.stopDownload.isHidden = true
                if let failure {
                    self.rebuildMenu()
                    report("STT: \(m.title)", failure)
                } else {
                    UserDefaults.standard.set(m.id, forKey: "model")
                    self.rebuildMenu()
                    self.load(m)
                }
            }
        })
        download = d
        rebuildMenu()
        d.start()
    }

    func stopFetching() {
        download?.cancel()
        download = nil; downloading = nil
        note.stringValue = ""
        stopDownload.isHidden = true
    }

    @objc func cancelDownload() {
        if let fileJob { fileJob.stop(); return }
        stopFetching()
        rebuildMenu()
    }

    @objc func showFolder() {
        NSWorkspace.shared.open(modelsFolder)
        rebuildMenu()
    }

    @objc func deleteModel(_ item: NSMenuItem) {
        defer { rebuildMenu() }
        let m = models[item.tag]
        let answer = alert(String(format: L("Delete %@?"), m.title), sizeText(m.size), [L("Delete"), L("Cancel")])
        guard answer == .alertFirstButtonReturn else { return }
        if m.id == current?.id {
            UserDefaults.standard.removeObject(forKey: "model")
            let engine = self.engine
            engine.queue.async { engine.unload() }
        }
        do {
            try FileManager.default.removeItem(at: m.path)
            // Nothing of the app stays once the last model is gone.
            for f in [modelsFolder, appFolder] where (try? FileManager.default.contentsOfDirectory(atPath: f.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: f)
            }
        } catch {
            report("STT: \(m.title)", "\(error)")
        }
    }

    func load(_ m: ASRModel) {
        note.stringValue = L("Loading…")
        let engine = self.engine
        engine.queue.async {
            do {
                try engine.load(path: m.path.path)
                DispatchQueue.main.async { self.note.stringValue = self.downloading == nil ? "" : self.note.stringValue; self.askPermissions() }
            } catch {
                DispatchQueue.main.async { self.note.stringValue = ""; report("STT: \(m.title)", "\(error)") }
            }
        }
    }

    // MARK: the job

    // A short press starts the recording and the next press ends it. Held longer than this, letting go ends it, so
    // both habits work with no setting. 0.5 s: long enough that an ordinary press never counts as a hold.
    let holdSeconds = 0.5

    func pressed() {
        if recording { finish(); return }
        guard current != nil else { window?.show(); return }   // or the words would be lost for want of a model
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { _ in }; return
        default:
            settingsAlert(L("STT has no access to the microphone."), "Privacy_Microphone")
            return
        }
        if isOn("pauseMedia") { media.stop() }
        if isOn("mute") { mute.on() }
        do {
            try recorder.start()
            recording = true
            pressedAt = Date()
        } catch {
            soundBack()
            report(L("Recording failed"), "\(error)")
        }
    }

    func released() {
        defer { pressedAt = nil }
        if recording, let t = pressedAt, Date().timeIntervalSince(t) >= holdSeconds { finish() }
    }

    func soundBack() {
        mute.off()
        media.resume()
    }

    func cancel() {
        guard recording else { return }
        recording = false
        _ = recorder.stop()
        soundBack()
    }

    func finish() {
        recording = false
        let pcm = recorder.stop()
        soundBack()
        transcribe(pcm)
    }

    // The recording exists only here, in memory, and goes when this ends. If recognition fails it can be tried again.
    func transcribe(_ pcm: [Float]) {
        let engine = self.engine
        engine.queue.async {
            do {
                let text = try engine.transcribe(pcm)
                DispatchQueue.main.async { self.deliver(text) }
            } catch {
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = L("Transcription failed")
                    a.informativeText = "\(error)"
                    a.addButton(withTitle: L("Try Again"))
                    a.addButton(withTitle: L("Copy"))
                    a.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    switch a.runModal() {
                    case .alertFirstButtonReturn: self.transcribe(pcm)
                    case .alertSecondButtonReturn:
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(L("Transcription failed"))\n\(error)", forType: .string)
                    default: break
                    }
                }
            }
        }
    }

    // A dropped file: its text goes into a .txt beside it, Finder shows that file. Nothing touches the clipboard,
    // and a dictation made meanwhile waits its turn on the engine's queue.
    final class FileJob: @unchecked Sendable {
        private let lock = NSLock(); private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var goOn: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    }
    var fileJob: FileJob?

    func transcribeFiles(_ urls: [URL]) {
        guard fileJob == nil, downloading == nil, !urls.isEmpty else { return }
        let job = FileJob()
        fileJob = job
        stopDownload.isHidden = false
        let engine = self.engine, working = L("Transcribing…")
        note.stringValue = working
        engine.queue.async {
            var written: [URL] = [], failures: [String] = []
            for (n, url) in urls.enumerated() where job.goOn {
                do {
                    let pcm = try readMedia(url)
                    let text = try engine.transcribe(pcm) { done in
                        let share = (Double(n) + done) / Double(urls.count)
                        DispatchQueue.main.async { self.note.stringValue = "\(working) \(Int(share * 100))%" }
                        return job.goOn
                    }
                    if text.isEmpty { failures.append("\(url.lastPathComponent): \(L("No speech found"))"); continue }
                    written.append(try saveBeside(url, text))
                } catch Failure.stopped {
                } catch Failure.noSound {
                    failures.append("\(url.lastPathComponent): \(L("Can’t read sound from this file"))")
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.fileJob = nil
                self.note.stringValue = ""
                self.stopDownload.isHidden = true
                if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
                if !failures.isEmpty { report(L("Transcription failed"), failures.joined(separator: "\n")) }
            }
        }
    }

    func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard pasteboard == .general, isOn("paste", true) else { return }
        guard AXIsProcessTrusted() else {
            settingsAlert(L("The text is on the clipboard. Pasting it needs Accessibility."), "Privacy_Accessibility")
            return
        }
        // 60 ms: an app reading the clipboard straight after the change can still see the old text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Self.pressPaste() }
    }

    static func pressPaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let v = CGKeyCode(keyCode(of: "v"))
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    func settingsAlert(_ text: String, _ pane: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: L("Open System Settings"))
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: start

// The physical key that types this letter in the person's Latin layout: the V of Cmd-V is elsewhere on Dvorak. Under a
// non-Latin layout such as Russian, macOS itself maps Command shortcuts through the Latin one, so that is the one to read.
func keyCode(of letter: String, in layout: TISInputSource? = nil) -> Int {
    guard let source = layout ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return kVK_ANSI_V }
    let data = unsafeBitCast(raw, to: CFData.self)
    let keys = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
    for key in 0..<128 {
        var dead: UInt32 = 0, count = 0
        var chars = [UniChar](repeating: 0, count: 4)
        UCKeyTranslate(keys, UInt16(key), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &count, &chars)
        if String(utf16CodeUnits: chars, count: count) == letter { return key }
    }
    return kVK_ANSI_V
}

// name.mp4 gives name.txt; an existing file is never overwritten.
func saveBeside(_ source: URL, _ text: String) throws -> URL {
    let folder = source.deletingLastPathComponent(), name = source.deletingPathExtension().lastPathComponent
    var out = folder.appendingPathComponent(name + ".txt"), n = 2
    while FileManager.default.fileExists(atPath: out.path) { out = folder.appendingPathComponent("\(name) (\(n)).txt"); n += 1 }
    try text.write(to: out, atomically: true, encoding: .utf8)
    return out
}

// Any file AVFoundation can open, video included: the first audio track as 16 kHz mono.
func readMedia(_ url: URL) throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure.noSound }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? Failure.noSound }
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: count))
        samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: $0.baseAddress! + start * MemoryLayout<Float>.size) }
    }
    if reader.status == .failed { throw reader.error ?? Failure.noSound }
    return samples
}

// Takes files dropped anywhere on the window. It lies over everything and lets clicks through.
final class DropView: NSView {
    var accepts: () -> Bool = { false }
    var dropped: ([URL]) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { accepts() ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dropped(urls)
        return !urls.isEmpty
    }
}

@main struct Main {
    static func main() {
        startInBackgroundIfAtLogin()
        Transcribe.disableLogging()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
            do {
                let e = Engine()
                let name = i + 2 < args.count ? args[i + 2] : models[0].file
                let t0 = Date()
                try e.load(path: name.contains("/") ? name : modelsFolder.appendingPathComponent(name).path)
                let t1 = Date()
                let text = try e.transcribe(try readMedia(URL(fileURLWithPath: args[i + 1])))
                FileHandle.standardError.write(String(format: "load %.2f s, run %.2f s\n", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)).data(using: .utf8)!)
                print(text)
                e.release()
                exit(0)
            } catch {
                FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        let pasteboard = args.count > 2 && args[1] == "--pasteboard" ? NSPasteboard(name: .init(args[2])) : .general

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = App(pasteboard: pasteboard)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
