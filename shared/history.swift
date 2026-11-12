// History (brief C of stt-iphone.md; why and how in stt.md, «Decisions», History bullets): every dictation, once
// transcribed, becomes one record; its audio lies beside it as a plain .m4a. Everything in one folder,
// Application Support/STT/History: History.sqlite (Core Data, with its -wal and -shm) and <uuid>.m4a. Nothing elsewhere.
// - Core Data, not SwiftData: the Mac app runs on macOS 13, SwiftData needs 14. The model is built in code, so the Mac's
//   plain swiftc build needs no compiled .momd.
// - Ready for brief F (texts through CloudKit, Apple's NSPersistentCloudKitContainer) without a migration: every
//   attribute optional or with a default, no unique constraints, no relations. Audio never syncs: a record whose file
//   is on another device simply has no audioURL.
// - The folder appears with the first record and nothing is created before (a person who never dictates gets nothing).
// - Keep: all, the last N, N days (30 by default, his word 2026-11-11: «как у всех стандартных приложений, месяц»), or
//   never (no history at all); a synced setting, like the language. What the setting no longer allows is erased
//   outright: the person chose the period.
// - Delete moves a record to Recently Deleted for 30 days, as Voice Memos does (his choice 2026-11-11); Recover brings
//   it back; Delete Forever, Delete All and the 30 days erase the row and its audio together. Purging runs after every
//   new record and at launch.
// - The schema is final before anyone keeps a history: the model is built in code, so a later attribute needs the old
//   model kept beside the new one and a mapping (Core Data cannot infer a migration from a model it can't find).
import CoreData
import AVFoundation

let historyFolder = appFolder.appendingPathComponent("History", isDirectory: true)

@objc(Recording) final class Recording: NSManagedObject, Identifiable {
    @NSManaged var id: UUID?
    @NSManaged var created: Date?
    @NSManaged var duration: Double      // seconds of speech recorded
    @NSManaged var text: String?
    @NSManaged var model: String?        // the model's id that made the text
    @NSManaged var language: String?     // what the person had chosen, nil = Automatic
    @NSManaged var audio: String?        // file name in historyFolder, nil once the audio is gone
    @NSManaged var edited: Date?         // last edit of the text by hand; brief F's merge uses it
    @NSManaged var removed: Date?        // in Recently Deleted since then; nil = in the list («deleted» is NSManagedObject's own)

    // The audio, if this device has it.
    var audioURL: URL? {
        guard let audio else { return nil }
        let u = historyFolder.appendingPathComponent(audio)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

// How much history a person keeps. Stored as a short string in the synced key `historyKeep`.
enum Keep: Equatable {
    case all, last(Int), days(Int), never
    static let key = "historyKeep"
    static let standard = Keep.days(30)   // the default for new people (his answer 2026-11-11 ~16:30)
    static let trashDays = 30.0           // Recently Deleted, as Voice Memos

    init(_ s: String?) {
        let p = (s ?? "").split(separator: ":")
        switch (p.first, p.count > 1 ? Int(p[1]) : nil) {
        case ("all", _): self = .all
        case ("never", _): self = .never
        case ("last", let n?) where n > 0: self = .last(n)
        case ("days", let n?) where n > 0: self = .days(n)
        default: self = Keep.standard
        }
    }
    var string: String {
        switch self { case .all: "all"; case .never: "never"; case .last(let n): "last:\(n)"; case .days(let n): "days:\(n)" }
    }
}

@MainActor final class History {
    static let shared = History()

    private var container: NSPersistentContainer?
    var context: NSManagedObjectContext? { open(create: false)?.viewContext }

    static let model: NSManagedObjectModel = {
        let e = NSEntityDescription()
        e.name = "Recording"; e.managedObjectClassName = "Recording"
        func a(_ name: String, _ type: NSAttributeType, optional: Bool = true, def: Any? = nil) -> NSAttributeDescription {
            let x = NSAttributeDescription(); x.name = name; x.attributeType = type; x.isOptional = optional
            x.defaultValue = def; return x
        }
        e.properties = [a("id", .UUIDAttributeType), a("created", .dateAttributeType),
                        a("duration", .doubleAttributeType, optional: false, def: 0.0), a("text", .stringAttributeType),
                        a("model", .stringAttributeType), a("language", .stringAttributeType),
                        a("audio", .stringAttributeType), a("edited", .dateAttributeType), a("removed", .dateAttributeType)]
        let m = NSManagedObjectModel(); m.entities = [e]; return m
    }()

    // The store, opened on first need; with create false a person without history gets no folder.
    private func open(create: Bool) -> NSPersistentContainer? {
        if let container { return container }
        let url = historyFolder.appendingPathComponent("History.sqlite")
        guard create || FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true) } catch { return nil }
        let c = NSPersistentContainer(name: "History", managedObjectModel: History.model)
        let d = NSPersistentStoreDescription(url: url)
        d.shouldAddStoreAsynchronously = false
        c.persistentStoreDescriptions = [d]
        var failed: Error?
        c.loadPersistentStores { _, e in failed = e }
        if let failed { NSLog("STT history: %@", failed.localizedDescription); return nil }
        c.viewContext.automaticallyMergesChangesFromParent = true
        container = c
        return c
    }

    var keep: Keep { Keep(Store.shared.object(Keep.key) as? String) }

    // The list, newest first.
    func all() -> [Recording] { fetch("removed == nil", "created") }
    // Recently Deleted, the last deleted first.
    func trash() -> [Recording] { fetch("removed != nil", "removed") }
    private func fetch(_ predicate: String?, _ key: String) -> [Recording] {
        guard let ctx = context else { return [] }
        let r = NSFetchRequest<Recording>(entityName: "Recording")
        if let predicate { r.predicate = NSPredicate(format: predicate) }
        r.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
        return (try? ctx.fetch(r)) ?? []
    }

    // Days left before Recently Deleted erases a record.
    nonisolated static func daysLeft(_ r: Recording) -> Int {
        let gone = (r.removed ?? Date()).addingTimeInterval(Keep.trashDays * 86400)
        return max(0, Int(ceil(gone.timeIntervalSinceNow / 86400)))
    }

    // A finished dictation. samples: 16 kHz mono, as the engine got them; kept as AAC in .m4a (about 0.25 MB a minute).
    @discardableResult
    func add(text: String, samples: [Float], model: String, language: String?) -> Recording? {
        guard keep != .never, !text.isEmpty, let ctx = open(create: true)?.viewContext else { return nil }
        let id = UUID()
        let name = id.uuidString + ".m4a"
        let saved = writeAudio(samples, to: historyFolder.appendingPathComponent(name))
        let r = Recording(context: ctx)
        r.id = id; r.created = Date(); r.duration = Double(samples.count) / 16000
        r.text = text; r.model = model; r.language = language; r.audio = saved ? name : nil
        save()
        purge()
        return r
    }

    func edit(_ r: Recording, text: String) {
        guard r.text != text else { return }
        r.text = text; r.edited = Date(); save()
    }

    // To Recently Deleted: nothing is lost yet, so nothing is asked (Voice Memos asks nothing either).
    func delete(_ rs: [Recording]) {
        let now = Date()
        for r in rs { r.removed = now }
        save()
    }

    func recover(_ rs: [Recording]) {
        for r in rs { r.removed = nil }
        save()
    }

    // For ever: the rows and their audio; the caller has asked the person once.
    func erase(_ rs: [Recording]) {
        guard let ctx = context else { return }
        for r in rs {
            if let u = r.audioURL { try? FileManager.default.removeItem(at: u) }
            ctx.delete(r)
        }
        save()
        tidy()
    }

    // Recently Deleted older than 30 days goes; then Keep: never empties everything, last N keeps the newest N, days N
    // keeps what is younger.
    func purge() {
        let old = Date().addingTimeInterval(-Keep.trashDays * 86400)
        let expired = trash().filter { ($0.removed ?? .distantPast) < old }
        if !expired.isEmpty { erase(expired) }
        let rs = all()
        switch keep {
        case .all: break
        case .never: if !rs.isEmpty || !trash().isEmpty { erase(rs + trash()) }
        case .last(let n): if rs.count > n { erase(Array(rs[n...])) }
        case .days(let n):
            let edge = Date().addingTimeInterval(-Double(n) * 86400)
            let gone = rs.filter { ($0.created ?? .distantPast) < edge }
            if !gone.isEmpty { erase(gone) }
        }
    }

    // How many recordings a new keep setting would erase (the person is asked once with this number).
    func wouldErase(_ k: Keep) -> Int {
        let rs = all()
        switch k {
        case .all: return 0
        case .never: return rs.count + trash().count
        case .last(let n): return max(0, rs.count - n)
        case .days(let n): return rs.filter { ($0.created ?? .distantPast) < Date().addingTimeInterval(-Double(n) * 86400) }.count
        }
    }

    // With no record left the folder goes too, as the models folder does with the last model.
    private func tidy() {
        guard all().isEmpty, trash().isEmpty, let c = container else { return }
        for s in c.persistentStoreCoordinator.persistentStores { try? c.persistentStoreCoordinator.remove(s) }
        container = nil
        try? FileManager.default.removeItem(at: historyFolder)
    }

    private func save() {
        guard let ctx = context, ctx.hasChanges else { return }
        do { try ctx.save() } catch { NSLog("STT history: %@", error.localizedDescription); ctx.rollback() }
    }
}

// AAC, mono, 16 kHz, 32 kbit/s: speech stays clear and a minute costs about a quarter of a megabyte.
func writeAudio(_ samples: [Float], to url: URL) -> Bool {
    guard !samples.isEmpty,
          let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                   AVEncoderBitRateKey: 32000]
    do {
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: buf)
        return true
    } catch { try? FileManager.default.removeItem(at: url); return false }
}
