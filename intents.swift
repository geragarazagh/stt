// Shortcuts actions (0.5): Start Recording, Stop Recording, Transcribe File. The road to a key, a schedule or the iPhone's
// Action Button that STT itself doesn't offer (his interview 2026-11-10, «одно из самых главных»).
// - Start and Stop act exactly as the app's key does: the same recording, paste and clipboard, the same switches. Stop
//   also hands the text to the shortcut, so it can go on to other actions.
// - Transcribe File gives the shortcut the file's text and nothing else: no .txt beside it (a shortcut's file is often a
//   copy with no folder of its own) and no clipboard; the shortcut decides where the text goes.
// - Shortcuts finds these through Metadata.appintents, which `build` makes with Xcode's appintentsmetadataprocessor from the
//   compiler's constant values (what Xcode does for an app; swiftc alone leaves the actions invisible).

import AppIntents
import AppKit

struct STTError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

@MainActor private var app: App? { NSApp.delegate as? App }

struct StartRecording: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts a recording, as the key of STT does.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        guard let app else { throw STTError(localizedStringResource: "STT is not ready yet.") }
        if let problem = app.startFromOutside() { throw STTError(localizedStringResource: problem) }
        return .result()
    }
}

struct StopRecording: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording and gives its text, which is also pasted as by the key of STT.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app else { return .result(value: "") }
        return .result(value: await app.stopFromOutside())
    }
}

struct TranscribeFile: AppIntent {
    static let title: LocalizedStringResource = "Transcribe File"
    static let description = IntentDescription("Turns speech in an audio or video file into text.")
    static let openAppWhenRun = false

    @Parameter(title: "File", supportedTypeIdentifiers: ["public.audio", "public.movie"])
    var file: IntentFile

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app else { throw STTError(localizedStringResource: "STT is not ready yet.") }
        // AVFoundation reads from a file, and the shortcut's file may exist only as data: a copy in the app's temporary
        // folder, under the file's own extension (the reader goes by it), removed straight after.
        // Letters and digits only: the name comes from wherever the shortcut got the file (security pass 2026-11-10).
        let given = file.fileURL?.pathExtension ?? file.filename.split(separator: ".").last.map(String.init) ?? ""
        let ext = given.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) && (1...8).contains(given.count) ? given : "m4a"
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do { try file.data.write(to: copy) } catch { throw STTError(localizedStringResource: "\(error.localizedDescription)") }
        defer { try? FileManager.default.removeItem(at: copy) }
        switch await app.transcribeForShortcut(copy) {
        case .success(let text): return .result(value: text)
        case .failure(Failure.noSound): throw STTError(localizedStringResource: "Can’t read sound from this file")
        case .failure(Failure.noModel): throw STTError(localizedStringResource: "No model chosen")
        case .failure(let error): throw STTError(localizedStringResource: "\(error.localizedDescription)")
        }
    }
}
