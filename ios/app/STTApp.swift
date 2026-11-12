// STT for iPhone: entry, the App Shortcuts (Action Button, Siri, Spotlight) and the shots mode.
import AppIntents
import SwiftUI

@main struct STTApp: App {
    @Environment(\.scenePhase) private var scene
    init() {
        Store.shared.start()          // what the person's other devices set comes first
        host = Dictation.shared       // the Shortcuts actions talk to this
        Dictation.shared.passSettings()
        Dictation.shared.preload()
        Dictation.shared.recover()
        Dictation.shared.closeLeftovers()
        trace("launch")
        #if DEBUG
        Demo.apply()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .onChange(of: scene) { _, now in trace("scene \(now)") }   // the Action Button tests read this
        }
    }
}

// App Shortcuts live in the app target only: the probe's copy in the widget extension took the Action Button's press and
// did nothing (stt-iphone.md, «Measured»). Record first: it is the one the Action Button runs.
struct STTShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .red   // the record red, as the control and the island
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: Record(), phrases: ["Record in \(.applicationName)", "\(.applicationName)"],
                    shortTitle: "Record", systemImageName: "waveform")   // App Shortcuts take SF Symbols only
    }
}
