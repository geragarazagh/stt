// STT, speech to text: a hot key starts recording, the same key stops it, and the text lands in the app in front.
// Offline: the only network call is downloading a model the user chose. No logs. History (since brief C): every
// dictation with its audio in one folder, Application Support/STT/History (shared/history.swift), shown in the main
// window (main-window.swift); the small window of before is the Settings window.
//
// Test the whole pipeline without microphone or clipboard: STT.app/Contents/MacOS/STT some.wav (the command line, cli.swift).
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
import AudioToolbox
import CoreAudio
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: microphone

// A new engine for every recording: it picks up whatever input device is the system default right now.
final class Recorder {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        // A Mac with no microphone at all (a Mac mini or Studio with nothing plugged in): AVAudioEngine raises an exception
        // for its input, which ended the app (found on a test machine with no sound input, 2026-11-10). So it is asked first.
        let noInput = NSError(domain: "STT", code: 1, userInfo: [NSLocalizedDescriptionKey: L("No microphone is connected.")])
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { throw noInput }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var other = notBluetooth(), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &other, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let from = input.outputFormat(forBus: 0)
        guard from.sampleRate > 0, from.channelCount > 0, let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to) else { throw noInput }
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

    // How loud the last 50 ms were, 0...1 (decibels, -55..-5 dB, as the iPhone's wave), for the running wave.
    func level() -> Float {
        lock.lock(); defer { lock.unlock() }
        let n = min(800, samples.count)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for x in samples[(samples.count - n)...] { sum += x * x }
        let db = 10 * log10(max(sum / Float(n), 1e-10))
        return max(0, min(1, (db + 55) / 50))
    }

    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

// A Bluetooth headset as the default input: taking its microphone switches it to the headset profile, which makes
// every sound the person hears thin and mono until the recording ends, and records them at 8-16 kHz. So the Mac's own
// microphone is taken instead, or any other one that isn't Bluetooth; only when there is none the headset is used.
// nil: keep the default.
func notBluetooth() -> AudioDeviceID? {
    func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr
    }
    func transport(_ d: AudioDeviceID) -> UInt32 { var t: UInt32 = 0; _ = get(d, kAudioDevicePropertyTransportType, &t); return t }
    func bluetooth(_ d: AudioDeviceID) -> Bool { [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(d)) }
    var current = AudioDeviceID(0)
    guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &current), bluetooth(current) else { return nil }
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
    let inputs = ids.filter { d in
        var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var n: UInt32 = 0
        return AudioObjectGetPropertyDataSize(d, &s, 0, nil, &n) == noErr && n > 0 && !bluetooth(d)
    }
    return inputs.first { transport($0) == kAudioDeviceTransportTypeBuiltIn } ?? inputs.first
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

@MainActor final class App: NSObject, NSApplicationDelegate, RecordingHost {
    let pasteboard: NSPasteboard
    let engine = Engine()
    let control = Control()
    let recorder = Recorder()
    let mute = Mute()
    let media = Media()
    var recording = false
    var pressedAt: Date?
    var window: AppWindow?
    var main: MainWindow?
    var levelTimer: Timer?
    let keepPicker = NSPopUpButton(frame: .zero)
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
        Store.shared.start()   // before the window reads its settings: what the person's other devices set comes first
        host = self
        mute.recoverAfterCrash()
        // A .part file lives only while the app runs; a crash can leave one behind.
        for m in models { try? FileManager.default.removeItem(at: m.path.appendingPathExtension("part")) }
        window = AppWindow(name: "STT", github: "https://github.com/geragarazagh/stt",
                           defaultShortcut: Shortcut(key: kVK_Space, mods: cmdKey | optionKey),
                           defaultCancel: Shortcut(key: kVK_Escape, mods: cmdKey), above: chooserRows(), extra: settingsRows(),
                           showsAtLaunch: false, release: { [weak self] in self?.released() }) { [weak self] in self?.pressed() }
        if let content = window?.panel.contentView {
            let drop = WindowDrop(frame: content.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.accepts = { [weak self] in self?.current != nil }
            drop.dropped = { [weak self] in self?.transcribeFiles($0) }
            content.addSubview(drop)
        }
        rebuildMenu()
        Words.onChange = { [weak self] in self?.passWords() }
        passWords()
        NotificationCenter.default.addObserver(forName: Store.changedFromCloud, object: nil, queue: .main) { [weak self] n in
            let keys = n.userInfo?["keys"] as? [String] ?? []
            MainActor.assumeIsolated { self?.changedElsewhere(keys) }
        }
        setUpShelf()
        History.shared.purge()   // what the keep setting no longer allows, also after a change on another device
        // No model: the Settings window, where the model is chosen. Otherwise the main window, unless STT started in the
        // background (Open at Login) with nothing to say.
        if let m = current {
            load(m)
            if window?.wantedAtLaunch == true { showMain(); demo() }
        } else { window?.show() }
        if AXIsProcessTrusted() { tryTap() }
        control.toggle = { [weak self] in
            guard let self else { return "STT is not ready." }
            if self.current == nil && !self.recording { return "No model: choose one in the STT window." }
            DispatchQueue.main.async { self.pressed() }   // answered first: an alert it may raise would hold the answer back
            return "ok"
        }
        control.start()
        launched = true
        // Opened by Finder with files: only the files window, unless there is no model to work with.
        if !openedAtLaunch.isEmpty {
            if current != nil { window?.panel.orderOut(nil) }
            openFiles(openedAtLaunch, from: launchSender)
            openedAtLaunch = []
        }
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
        if current == nil { window?.show() } else { showMain() }
        return false
    }

    func applicationWillTerminate(_ n: Notification) {
        if recording || stopping { _ = recorder.stop(); soundBack() }
        control.stop()
        download?.cancel()
        for m in models { try? FileManager.default.removeItem(at: m.path.appendingPathExtension("part")) }
        engine.queue.sync { engine.release() }
    }

    // MARK: settings

    // Model and language first: a shortcut means nothing without a model, and what is on offer depends on it.
    func chooserRows() -> NSView {
        // The pickers take the same column as the key buttons below them. The line under them shows a download.
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 74))
        func label(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13)
            l.frame = NSRect(x: 20, y: y, width: 136, height: 18)
            row.addSubview(l)
        }
        label(L("Model"), 53)
        picker.frame = NSRect(x: 340 - 20 - 160, y: 48, width: 160, height: 26)
        picker.target = self; picker.action = #selector(picked)
        picker.refusesFirstResponder = true
        row.addSubview(picker)
        label(L("Language"), 23)
        languagePicker.frame = NSRect(x: 340 - 20 - 160, y: 18, width: 160, height: 26)
        languagePicker.target = self; languagePicker.action = #selector(pickedLanguage)
        languagePicker.refusesFirstResponder = true
        row.addSubview(languagePicker)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .right
        note.frame = NSRect(x: 20, y: 0, width: 300, height: 14)
        row.addSubview(note)
        stopDownload.title = L("Cancel")
        stopDownload.bezelStyle = .rounded
        stopDownload.controlSize = .small
        stopDownload.font = .systemFont(ofSize: 11)
        stopDownload.sizeToFit()
        stopDownload.frame.origin = NSPoint(x: 20, y: 0)
        stopDownload.target = self; stopDownload.action = #selector(cancelDownload)
        stopDownload.refusesFirstResponder = true
        stopDownload.isHidden = true
        row.addSubview(stopDownload)
        return row
    }

    // Below Open at Login, in groups with the window's own gap between groups (51 pt from the middle of a group's last row
    // to the middle of the next one's first, as from Language to Recording; 30 pt between rows inside a group), his
    // order 2026-11-10: Pause Media and Mute Sound together, since both act while recording; Paste Text alone, since it
    // follows recognition; then the row that transcribes a file, an action and not a setting, with its one switch under it
    // (0.5: subtitles beside the text, a file's own option, so it sits in the file's group); the dictionary as a group of
    // its own.
    // Open at Login (window.swift) sits with its middle 18 pt above this view's top edge, so the rows count down from it.
    func settingsRows() -> NSView {
        let gap: CGFloat = 51, step: CGFloat = 30
        let pause = 18 - gap, mute = pause - step, paste = mute - gap, file = paste - gap, subtitles = file - step - 2, words = subtitles - gap - 2   // middles
        let history = words - gap
        let height = -history + 14   // the history row's menu is 28 tall and ends at the bottom edge
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: height))
        func label(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13)
            l.frame = NSRect(x: 20, y: y, width: 240, height: 18)
            row.addSubview(l)
        }
        func toggle(_ s: String, _ key: String, _ standard: Bool, _ middle: CGFloat) {
            let y = height + middle - 10
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
            switches[key] = (t, standard)
        }
        toggle(L("Pause Media"), "pauseMedia", false, pause)
        toggle(L("Mute Sound"), "mute", false, mute)
        toggle(L("Paste Text"), "paste", true, paste)
        toggle(L("Save Subtitles (.srt)"), "subtitles", false, subtitles)
        // Two actions, not settings: a real push button each in the column of the key buttons, their frame and style (his
        // word 2026-11-10: a dashed «Drop Here» well didn't look clickable). A push button is 28 tall against a switch's
        // 20, so the rows next to one sit 2 pt further away than the plain steps.
        func action(_ s: String, _ b: NSButton, _ title: String, _ middle: CGFloat, _ selector: Selector) {
            let y = height + middle - 14
            label(s, y + 5)
            b.title = title
            b.frame = NSRect(x: 340 - 20 - 160, y: y, width: 160, height: 28)
            b.bezelStyle = .rounded
            b.target = self; b.action = selector
            b.refusesFirstResponder = true
            row.addSubview(b)
        }
        // The system's file chooser at once.
        action(L("Transcribe File"), chooseButton, L("Choose File…"), file, #selector(chooseFiles))
        action(L("Dictionary"), wordsButton, L("Edit…"), words, #selector(showDictionary))
        // How much history is kept: a menu in the same column (synced, like the language).
        label(L("History"), height + history - 9)
        keepPicker.frame = NSRect(x: 340 - 20 - 160, y: height + history - 14, width: 160, height: 26)
        keepPicker.target = self; keepPicker.action = #selector(pickedKeep)
        keepPicker.refusesFirstResponder = true
        row.addSubview(keepPicker)
        rebuildKeep()
        return row
    }

    let wordsButton = NSButton(title: "", target: nil, action: nil)
    var dictionary: DictionaryWindow?
    @objc func showDictionary() {
        if dictionary == nil {
            let w = DictionaryWindow()
            w.beside = { [weak self] in self?.window?.panel }
            w.takesWords = { [weak self] in self?.current?.id != "parakeet-ultra" }
            dictionary = w
        }
        dictionary?.show()
    }

    // The engine gets its own copy on its queue, at launch and after every change in the dictionary window.
    func passWords() {
        let all = Words.words, preset = Set(presetWords.map { $0.lowercased() }), pairs = Words.replacements
        let own = all.filter { !preset.contains($0.lowercased()) }, builtIn = all.filter { preset.contains($0.lowercased()) }
        let engine = self.engine
        engine.queue.async { engine.ownWords = own; engine.builtIn = builtIn; engine.pairs = pairs }
    }

    // Cancelled, nothing else opens; chosen, the files window shows the work.
    @objc func chooseFiles() {
        guard current != nil, let main = NSApp.keyWindow ?? window?.panel else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.audiovisualContent]
        p.prompt = L("Transcribe")
        p.beginSheetModal(for: main) { [weak self] r in
            if r == .OK, !p.urls.isEmpty { self?.transcribeFiles(p.urls) }
        }
    }

    var switches: [String: (view: NSSwitch, standard: Bool)] = [:]

    @objc func switched(_ t: NSSwitch) {
        if let key = t.identifier?.rawValue { Store.shared.set(t.state == .on, key) }
    }

    // Values another device of the person's set (store.swift): the window and the engine follow at once.
    func changedElsewhere(_ keys: [String]) {
        for key in keys {
            if let s = switches[key] { s.view.state = isOn(key, s.standard) ? .on : .off }
        }
        if keys.contains("language") { rebuildLanguages() }
        if keys.contains(Keep.key) { rebuildKeep(); History.shared.purge(); Shelf.shared.reload() }
        if keys.contains("words") || keys.contains("replacements") { passWords(); dictionary?.reload(elsewhere: true) }
    }

    func isOn(_ key: String, _ standard: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? standard
    }

    // The list: each model with what a person needs to choose it. Then the folder, and the delete for the one in use.
    func rebuildMenu() {
        chooseButton.isEnabled = current != nil   // with no model there is nothing to transcribe with
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
        Store.shared.set(languagePicker.selectedItem?.representedObject as? String, "language")
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
        dictionary?.refresh()   // its line about Parakeet follows the model
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
        if stopping { return }
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
            showRecording()
        } catch {
            soundBack()
            report(L("Recording failed"), (error as NSError).domain == "STT" ? error.localizedDescription : "\(error)")
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
        levelTimer?.invalidate()
        Shelf.shared.phase = .idle
    }

    // The last word often ends as the key goes down, and the sound of it reaches the recorder a little later: 0.3 s more
    // keeps it (the silence after it is cut by the voice detector anyway). Sound and media come back after that, so the
    // tail doesn't record them. A press during the tail is ignored.
    let tailSeconds = 0.3
    var stopping = false
    func finish() {
        recording = false
        stopping = true
        levelTimer?.invalidate()
        Shelf.shared.stopped = Date(); Shelf.shared.phase = .transcribing
        DispatchQueue.main.asyncAfter(deadline: .now() + tailSeconds) { [self] in
            stopping = false
            let pcm = recorder.stop()
            soundBack()
            transcribe(pcm)
        }
    }

    // The recording exists only here, in memory, and goes when this ends. If recognition fails it can be tried again.
    func transcribe(_ pcm: [Float]) {
        let engine = self.engine
        engine.queue.async {
            do {
                let text = try engine.transcribe(pcm)
                // A Stop Recording action gets what the clipboard got: nothing while a password field is active.
                DispatchQueue.main.async {
                    let delivered = self.deliver(text)
                    self.handOut(delivered ? text : "")
                    Shelf.shared.phase = .idle
                    // Not kept when a password field withheld it: it may be a password said aloud.
                    if delivered, let r = History.shared.add(text: text, samples: pcm, model: self.current?.id ?? "",
                                                  language: UserDefaults.standard.string(forKey: "language")) { Shelf.shared.added(r) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.handOut("")
                    Shelf.shared.phase = .idle
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

    // MARK: Shortcuts (shared/intents.swift)

    // What a Stop Recording action waits for: the text of the recording it stopped.
    var textWaiters: [(String) -> Void] = []
    func handOut(_ text: String) { let w = textWaiters; textWaiters = []; for f in w { f(text) } }

    var isRecording: Bool { recording || stopping }

    // As a press of the key, when nothing is recording yet. nil: recording.
    func startFromOutside() -> LocalizedStringResource? {
        if recording || stopping { return nil }
        guard current != nil else { return "No model chosen" }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return "STT has no access to the microphone." }
        pressed()
        return recording ? nil : "Recording failed"
    }

    func stopFromOutside() async -> String {
        guard recording || stopping else { return "" }
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            textWaiters.append { c.resume(returning: $0) }
            if recording { finish() }
        }
    }

    func transcribeForShortcut(_ url: URL) async -> Result<String, Error> {
        guard current != nil else { return .failure(Failure.noModel) }
        let engine = self.engine
        return await withCheckedContinuation { (c: CheckedContinuation<Result<String, Error>, Never>) in
            engine.queue.async {
                do { c.resume(returning: .success(try engine.transcribe(try readMedia(url)))) } catch { c.resume(returning: .failure(error)) }
            }
        }
    }

    // Files, from the files window or Finder's Open With: each one's text goes into a .txt beside it, and all of it onto
    // the clipboard, never pasted. A dictation made meanwhile waits its turn on the engine's queue. Files that arrive
    // during a job join its queue.
    final class FileJob: @unchecked Sendable {
        private let lock = NSLock(); private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var goOn: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    }
    var fileJob: FileJob?
    var fileQueue: [URL] = [], fileCount = 0, written: [URL] = [], texts: [String] = [], failures: [String] = []
    lazy var files: FilesWindow = {
        let w = FilesWindow()
        w.hasModel = { [weak self] in self?.current != nil }
        w.beside = { [weak self] in self?.window?.panel }
        w.start = { [weak self] in self?.transcribeFiles($0) }
        w.cancel = { [weak self] in self?.fileJob?.stop(); self?.fileQueue = [] }
        return w
    }()
    var launched = false, openedAtLaunch: [URL] = [], launchSender: (trusted: Bool, name: String) = (false, "")

    let chooseButton = NSButton(title: "", target: nil, action: nil)

    // Finder's Open With, also at launch: then it comes before applicationDidFinishLaunching, and the job waits for the
    // model to be loaded first, since both go through the engine's one queue in order.
    func application(_ a: NSApplication, open urls: [URL]) {
        let sender = openSender()
        guard launched else { openedAtLaunch += urls; launchSender = sender; return }
        openFiles(urls, from: sender)
    }

    // Who asked: Finder's Open With and a drop on the Dock icon are a person's own hand; anything else (another program
    // through LaunchServices, `open -a STT` included) is asked about first, since the file's text then lands on the
    // clipboard where that program can read it, and STT may be able to read a folder that program can't (security pass
    // 2026-11-10). A sandboxed program is refused by macOS itself before STT hears anything (measured on 26.6).
    func openSender() -> (trusted: Bool, name: String) {
        guard let e = NSAppleEventManager.shared().currentAppleEvent,
              let pid = e.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 else { return (false, L("another program")) }
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier, ["com.apple.finder", "com.apple.dock"].contains(id) { return (true, "") }
        var name = [CChar](repeating: 0, count: 256)
        // `open -a STT …` from a terminal has usually exited by now: then no name is left to give.
        return (false, app?.localizedName ?? (proc_name(pid, &name, 256) > 0 ? String(cString: name) : L("another program")))
    }

    func openFiles(_ urls: [URL], from sender: (trusted: Bool, name: String)) {
        if !sender.trusted, current != nil {
            let title = urls.count == 1 ? String(format: L("Transcribe “%@”?"), urls[0].lastPathComponent) : String(format: L("Transcribe %d files?"), urls.count)
            guard alert(title, String(format: L("Asked by %@."), sender.name), [L("Transcribe"), L("Cancel")])
                == .alertFirstButtonReturn else { return }
        }
        files.show()
        if current == nil { window?.show(); return }
        transcribeFiles(urls)
    }

    func transcribeFiles(_ urls: [URL]) {
        guard current != nil, !urls.isEmpty else { return }
        fileQueue += urls
        fileCount += urls.count
        files.show()
        if fileJob == nil { written = []; texts = []; failures = []; nextFile(FileJob()) }
    }

    private func nextFile(_ job: FileJob) {
        guard job.goOn, !fileQueue.isEmpty else { return filesDone() }
        fileJob = job
        let url = fileQueue.removeFirst(), n = fileCount - fileQueue.count, count = fileCount
        let name = url.lastPathComponent
        files.showWork(name, 0, n, count)
        let engine = self.engine, subtitles = isOn("subtitles")
        engine.queue.async {
            var result: Result<(text: String, cues: [Cue]), Error>
            // The folder is opened now, before the file is read, and the texts go into exactly this folder later, even if
            // its path is swapped for a link meanwhile (security pass 2026-11-10: a sender owning the folder could
            // otherwise have STT create files where only STT may write).
            let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC), folderError = errno
            do {
                let pcm = try readMedia(url)
                result = .success(try engine.transcribeTimed(pcm) { done in
                    DispatchQueue.main.async { if job.goOn { self.files.showWork(name, done, n, count) } }
                    return job.goOn
                })
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                defer { if folder >= 0 { close(folder) } }
                switch result {
                case .success(let r) where r.text.isEmpty: self.failures.append("\(name): \(L("No speech found"))")
                case .success(let r):
                    let text = r.text
                    self.texts.append(text)
                    do {
                        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: folderError) ?? .EACCES) }
                        self.written.append(try saveBeside(url, in: folder, text, subtitles: subtitles ? srt(r.cues) : nil))
                    } catch {
                        self.failures.append("\(name): \(error.localizedDescription) \(L("The text is on the clipboard."))")
                    }
                case .failure(Failure.stopped): break
                case .failure(Failure.noSound): self.failures.append("\(name): \(L("Can’t read sound from this file"))")
                case .failure(let error): self.failures.append("\(name): \(error.localizedDescription)")
                }
                self.nextFile(job)
            }
        }
    }

    private func filesDone() {
        let stopped = fileJob?.goOn == false
        fileJob = nil; fileQueue = []; fileCount = 0
        // The clipboard gets the text even when the .txt could not be written, so nothing is lost.
        if !texts.isEmpty {
            pasteboard.clearContents()
            pasteboard.setString(texts.joined(separator: "\n\n"), forType: .string)
        }
        if !written.isEmpty {
            files.showDone(written)
        } else {
            files.showIdle()
        }
        if !failures.isEmpty && !stopped { report(L("Transcription failed"), failures.joined(separator: "\n")) }
    }

    // A password field is in front (macOS's Secure Input is on): the text is neither pasted nor left on the clipboard,
    // where any app could read it. The alert says so, since nothing else would show that the dictation went nowhere.
    // Some apps hold Secure Input for a while after their password field (a terminal's Secure Keyboard Entry too).
    @discardableResult func deliver(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if IsSecureEventInputEnabled() {
            let a = NSAlert()
            a.messageText = L("A password field is active")
            a.informativeText = L("The text was not pasted or copied.")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard pasteboard == .general, isOn("paste", true) else { return true }
        // STT's main window in front (a recording started with its button, or the key pressed over it): ⌘V would land in
        // the open recording's text. The text is in the history and on the clipboard. Its other windows take the paste
        // like any app's (a word said into the Dictionary window, his case of 2026-11-11).
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let m = main?.window, NSApp.keyWindow === m { return true }
        guard AXIsProcessTrusted() else {
            settingsAlert(L("The text is on the clipboard. Pasting it needs Accessibility."), "Privacy_Accessibility")
            return true
        }
        // 60 ms: an app reading the clipboard straight after the change can still see the old text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Self.pressPaste() }
        return true
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

// name.mp4 gives name.txt, and name.srt with subtitles on; an existing file (or link) is never overwritten or followed, and
// the two keep one name between them (name (2).txt goes with name (2).srt). Written into the folder opened before the read.
func saveBeside(_ source: URL, in folder: Int32, _ text: String, subtitles: String? = nil) throws -> URL {
    let name = source.deletingPathExtension().lastPathComponent
    for n in 1...10_000 {
        let base = n == 1 ? name : "\(name) (\(n))"
        let files = [(base + ".txt", text)] + (subtitles.map { [(base + ".srt", $0)] } ?? [])
        var st = stat()
        if files.contains(where: { fstatat(folder, $0.0, &st, AT_SYMLINK_NOFOLLOW) == 0 }) { continue }
        var made: [String] = []
        do {
            for (file, body) in files { try create(folder, file, body); made.append(file) }
            return source.deletingLastPathComponent().appendingPathComponent(base + ".txt")
        } catch let e as POSIXError where e.code == .EEXIST {
            for f in made { unlinkat(folder, f, 0) }   // taken between the look and the write: the next name
        } catch {
            for f in made { unlinkat(folder, f, 0) }
            throw error
        }
    }
    throw POSIXError(.EEXIST)
}

// A new file only (O_EXCL), never through a link (O_NOFOLLOW), readable by all as a text file is (0644).
private func create(_ folder: Int32, _ name: String, _ body: String) throws {
    let fd = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let bytes = Array(body.utf8)
    var done = 0
    while done < bytes.count {
        let w = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard w > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        done += w
    }
}

@main struct Main {
    static func main() {
        Transcribe.disableLogging()
        let args = CommandLine.arguments
        // The command line (cli.swift) exits when it is one; the app goes on otherwise.
        _ = MainActor.assumeIsolated { runCommandLine(args) }
        startInBackgroundIfAtLogin()

        // For tests from a terminal only: a copy started as an app (`open -n … --args --pasteboard X`) would send every
        // dictation to a pasteboard of somebody else's choosing (security pass 2026-11-10).
        let pasteboard = args.count > 2 && args[1] == "--pasteboard" && !answersForItself() ? NSPasteboard(name: .init(args[2])) : .general

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = App(pasteboard: pasteboard)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
