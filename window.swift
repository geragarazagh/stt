// The app's whole interface: one small window of a fixed size. Opening the app shows it, closing it
// leaves the hot key working in the background, with nothing in the Dock or the menu bar.
// The same file is used by every app that works through a hot key.
//
// - The hot key is a Carbon RegisterEventHotKey: it needs no Accessibility permission. It is stored
//   as a virtual key code, a physical key, so it works in every keyboard layout.
// - macOS does not report a key held by another app (RegisterEventHotKey answered noErr with the key
//   already taken) and acts on its own keys before an app hears them; turning them off during
//   recording needs Accessibility, which isn't worth asking for. So only what reaches the app is checked.

import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var key: Int    // virtual key code
    var mods: Int   // Carbon modifiers: cmdKey, optionKey, controlKey, shiftKey
}

private let functionKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
    kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
    kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"]

private let namedKeys: [Int: String] = [
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
    kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦", kVK_Delete: "⌫", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Escape: "Esc"]

// The Latin character of a key, whatever layout is on: a shortcut reads ⌘K, not ⌘Л.
private func keyName(_ key: Int) -> String {
    if let name = functionKeys[key] ?? namedKeys[key] { return name }
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
    let data = unsafeBitCast(raw, to: CFData.self)
    let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
    var dead: UInt32 = 0, count = 0
    var chars = [UniChar](repeating: 0, count: 4)
    UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &count, &chars)
    return String(utf16CodeUnits: chars, count: count).uppercased()
}

private func title(_ s: Shortcut) -> String {
    (s.mods & controlKey != 0 ? "⌃" : "") + (s.mods & optionKey != 0 ? "⌥" : "")
        + (s.mods & shiftKey != 0 ? "⇧" : "") + (s.mods & cmdKey != 0 ? "⌘" : "") + keyName(s.key)
}

// Keys macOS lists as its own. Most never reach the app; the ones that do are named as a conflict.
private func takenByMacOS(_ s: Shortcut) -> Bool {
    var list: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&list) == noErr, let all = list?.takeRetainedValue() as? [[String: Any]] else { return false }
    let mask = cmdKey | optionKey | controlKey | shiftKey
    return all.contains {
        ($0[kHISymbolicHotKeyEnabled] as? Bool) == true && ($0[kHISymbolicHotKeyCode] as? Int) == s.key
            && (($0[kHISymbolicHotKeyModifiers] as? Int) ?? -1) & mask == s.mods
    }
}

// Open at Login is a launchd agent (Contents/Library/LaunchAgents in the bundle) that passes --login:
// an app started as a login item can't otherwise tell that from being opened by hand, and only the
// second should show the window. The agent's copy only starts the app through `open` and exits,
// because launchd kills what it started when the agent is unregistered, and that would take the
// running app down with the switch.
func startInBackgroundIfAtLogin() {
    guard CommandLine.arguments.contains("--login") else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    if !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", Bundle.main.bundlePath, "--args", "--background"]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}

// The English text is the key; ru and uk come from lang/, picked by macOS from the system language.
// Wording of macOS's own terms (Open at Login, Quit, Privacy & Security) is copied from its .loctable files.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

// Carbon's handler is a C function and can capture nothing.
private var onHotKey: (() -> Void)?
private var onHotKeyUp: (() -> Void)?

func report(_ title: String, _ details: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
    field.string = details; field.isEditable = false; field.isSelectable = true
    field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    let scroll = NSScrollView(frame: field.frame); scroll.documentView = field; scroll.hasVerticalScroller = true
    a.accessoryView = scroll
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: L("Copy"))
    if a.runModal() == .alertSecondButtonReturn {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(title)\n\(details)", forType: .string)
    }
}

@MainActor final class AppWindow: NSObject, NSWindowDelegate {
    let name: String
    let github: String
    let login: SMAppService
    var shortcut: Shortcut
    var hotKey: EventHotKeyRef?
    var cancelKey: Shortcut? // a second recorded key, for an app that has something to cancel
    var recordingCancel = false
    var tapOwnsKeys = false  // an app with its own event tap hears macOS's keys too, so they are allowed
    let extra: NSView?       // an app's own row, between Open at Login and the links
    var recording = false
    let panel: NSPanel
    let keyButton = NSButton(title: "", target: nil, action: nil)
    let cancelButton = NSButton(title: "", target: nil, action: nil)
    let loginSwitch = NSSwitch()
    let status = NSTextField(labelWithString: "")

    init(name: String, github: String, defaultShortcut: Shortcut, defaultCancel: Shortcut? = nil, extra: NSView? = nil, release: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.extra = extra
        self.name = name
        self.github = github
        let id = Bundle.main.bundleIdentifier ?? ""
        login = SMAppService.agent(plistName: "\(id).login.plist")
        let d = UserDefaults.standard
        shortcut = d.object(forKey: "key") == nil ? defaultShortcut : Shortcut(key: d.integer(forKey: "key"), mods: d.integer(forKey: "mods"))
        cancelKey = d.object(forKey: "cancelKey") == nil ? defaultCancel : Shortcut(key: d.integer(forKey: "cancelKey"), mods: d.integer(forKey: "cancelMods"))
        // Non-activating: it takes the keys even when macOS declines to bring a background app forward.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 278 + (defaultCancel == nil ? 0 : 34) + (extra?.frame.height ?? 0)), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        onHotKey = action
        onHotKeyUp = release
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { if pressed { onHotKey?() } else { onHotKeyUp?() } }
            return noErr
        }, 2, &specs, nil, nil)

        build()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.keyDown(e)
        }

        let registered = register(shortcut) == noErr
        // Open at Login stays off until a person turns it on: an app adds nothing to their login items by itself.
        // The switch is in this window, which the first launch shows.
        let first = !d.bool(forKey: "launched")
        if first { d.set(true, forKey: "launched") }
        if first || !registered || !CommandLine.arguments.contains("--background") { show() }
        if !registered { startRecording(); status.stringValue = L("This shortcut can’t be used") }
    }

    // MARK: window

    func build() {
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let v = panel.contentView!
        let W: CGFloat = 340, M: CGFloat = 20
        let up = extra?.frame.height ?? 0   // everything above the links moves up by the extra row
        let top = up + (cancelKey == nil ? 0 : 34)   // and everything above the shortcuts by the second one
        if let extra { extra.frame.origin = NSPoint(x: 0, y: 50); v.addSubview(extra) }

        func text(_ s: String, _ font: NSFont, _ color: NSColor, _ frame: NSRect, _ align: NSTextAlignment) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = font; l.textColor = color; l.alignment = align; l.frame = frame
            v.addSubview(l)
            return l
        }

        let icon = NSImageView(frame: NSRect(x: (W - 64) / 2, y: 188 + top, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        v.addSubview(icon)
        _ = text(name, .boldSystemFont(ofSize: 15), .labelColor, NSRect(x: M, y: 162 + top, width: W - 2 * M, height: 20), .center)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        _ = text(version, .systemFont(ofSize: 11), .secondaryLabelColor, NSRect(x: M, y: 146 + top, width: W - 2 * M, height: 14), .center)

        func keyRow(_ label: String, _ button: NSButton, _ y: CGFloat, _ action: Selector) {
            _ = text(label, .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: y + 5, width: 136, height: 18), .left)
            button.frame = NSRect(x: W - M - 160, y: y, width: 160, height: 28)
            button.bezelStyle = .rounded
            button.setButtonType(.pushOnPushOff)
            button.target = self; button.action = action
            button.refusesFirstResponder = true
            v.addSubview(button)
        }
        // With a second key the first one needs its own name: «Сочетание клавиш» beside «Отмена записи» said nothing.
        keyRow(cancelKey != nil ? L("Recording") : L("Shortcut"), keyButton, 106 + top, #selector(keyButtonClicked))
        if cancelKey != nil { keyRow(L("Cancel Recording"), cancelButton, 106 + up, #selector(cancelButtonClicked)) }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.frame = NSRect(x: M, y: 88 + up, width: W - 2 * M, height: 14)
        v.addSubview(status)

        _ = text(L("Open at Login"), .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: 59 + up, width: 236, height: 18), .left)
        loginSwitch.controlSize = .small
        loginSwitch.sizeToFit()
        loginSwitch.frame.origin = NSPoint(x: W - M - loginSwitch.frame.width + 5, y: 58 + up)   // the switch draws 5 pt inside its frame
        loginSwitch.target = self; loginSwitch.action = #selector(loginChanged)
        loginSwitch.refusesFirstResponder = true
        v.addSubview(loginSwitch)

        var x = M
        for (label, url) in [(L("Herman Harazha"), "https://geragaraza.com"), (L("GitHub"), github)] {
            let b = NSButton(title: label, target: self, action: #selector(openLink(_:)))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor])
            b.toolTip = url
            b.refusesFirstResponder = true
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: 20)
            v.addSubview(b)
            x += b.frame.width + 12
        }
        // A background app with no menu has no other way to be stopped.
        let quit = NSButton(title: L("Quit"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)
        quit.refusesFirstResponder = true
        quit.sizeToFit()
        quit.frame.origin = NSPoint(x: W - M - quit.frame.width, y: 16)
        v.addSubview(quit)
    }

    func show() {
        refresh()
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        keyButton.title = hotKey == nil && !tapOwnsKeys ? L("None") : title(shortcut)
        keyButton.state = .off
        if let cancelKey { cancelButton.title = title(cancelKey); cancelButton.state = .off }
        status.stringValue = ""
        loginSwitch.state = login.status == .enabled ? .on : .off
    }

    func windowDidBecomeKey(_ n: Notification) { loginSwitch.state = login.status == .enabled ? .on : .off }
    func windowDidResignKey(_ n: Notification) { cancelRecording() }
    func windowWillClose(_ n: Notification) { cancelRecording() }

    @objc func openLink(_ b: NSButton) {
        if let s = b.toolTip, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc func loginChanged() {
        do {
            if loginSwitch.state == .on {
                if login.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } else { try login.register() }
            } else {
                try login.unregister()
            }
        } catch {
            report("\(name): \(L("Open at Login"))", "\(error)")
        }
        loginSwitch.state = login.status == .enabled ? .on : .off
    }

    // MARK: hot key

    func register(_ s: Shortcut) -> OSStatus {
        unregister()
        // With the window in front a Carbon key fires even though the tap took the key, and one press would count twice.
        if tapOwnsKeys { return noErr }
        let id = EventHotKeyID(signature: OSType(0x4B45_5931), id: 1)
        return RegisterEventHotKey(UInt32(s.key), UInt32(s.mods), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    // MARK: recording

    @objc func keyButtonClicked() {
        let same = recording && !recordingCancel
        cancelRecording()
        if !same { startRecording() }
    }

    @objc func cancelButtonClicked() {
        let same = recording && recordingCancel
        cancelRecording()
        if !same { recording = true; recordingCancel = true; cancelButton.title = L("Press a shortcut"); cancelButton.state = .on; status.stringValue = "" }
    }

    // The current key is unregistered first: a registered hot key never reaches the app as a key
    // press, so pressing the same key again could not be recorded.
    func startRecording() {
        recording = true
        unregister()
        keyButton.title = L("Press a shortcut")
        keyButton.state = .on
        status.stringValue = ""
    }

    func cancelRecording() {
        guard recording else { return }
        recording = false
        if !recordingCancel { _ = register(shortcut) }
        recordingCancel = false
        refresh()
    }

    // Esc leaves the recording of the main key. For the cancel key Esc is a value people want, and the button leaves it.
    func recorded(key: Int, mods: Int) {
        if key == kVK_Escape && mods == 0 && !recordingCancel { cancelRecording() } else { record(key: key, mods: mods) }
    }

    func keyDown(_ e: NSEvent) -> NSEvent? {
        guard e.window === panel else { return e }
        let f = e.modifierFlags
        var mods = 0
        if f.contains(.command) { mods |= cmdKey }
        if f.contains(.option) { mods |= optionKey }
        if f.contains(.control) { mods |= controlKey }
        if f.contains(.shift) { mods |= shiftKey }
        let key = Int(e.keyCode)

        guard recording else {
            if key == kVK_Escape && mods == 0 || key == kVK_ANSI_W && mods == cmdKey { panel.performClose(nil); return nil }
            if key == kVK_ANSI_Q && mods == cmdKey { NSApp.terminate(nil); return nil }
            return e
        }
        recorded(key: key, mods: mods)
        return nil
    }

    func record(key: Int, mods: Int) {
        let new = Shortcut(key: key, mods: mods)
        // A plain letter or Shift + letter would stop typing that letter everywhere. F-keys type nothing.
        if mods & (cmdKey | optionKey | controlKey) == 0 && functionKeys[key] == nil && !(recordingCancel && key == kVK_Escape) {
            status.stringValue = L("Needs ⌘, ⌥ or ⌃")
            return
        }
        if recordingCancel {
            if new == shortcut { status.stringValue = L("Already in use"); return }
            cancelKey = new
            UserDefaults.standard.set(key, forKey: "cancelKey")
            UserDefaults.standard.set(mods, forKey: "cancelMods")
            recording = false; recordingCancel = false
            refresh()
            return
        }
        if new == cancelKey { status.stringValue = L("Already in use"); return }
        if !tapOwnsKeys && takenByMacOS(new) { status.stringValue = L("Conflicts with macOS"); return }
        if register(new) != noErr && !tapOwnsKeys { status.stringValue = L("This shortcut can’t be used"); return }
        shortcut = new
        UserDefaults.standard.set(key, forKey: "key")
        UserDefaults.standard.set(mods, forKey: "mods")
        recording = false
        refresh()
    }
}
