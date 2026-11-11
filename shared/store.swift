// Settings, kept in this device's UserDefaults as before, and the ones a person sets once for all their devices also in
// iCloud key-value storage (0.6): the same on every Mac and iPhone signed into one iCloud account, with no switch, the
// way macOS's own text replacements follow a person. Which keys: what is about the person and the language they speak
// (language, the dictionary, the subtitles switch); the model, the keys, the sound and paste switches and Open at Login
// stay with the device, since devices differ (an iPhone has no hot key, a smaller Mac may want a smaller model).
// - UserDefaults stays the truth: with no iCloud account, iCloud turned off or a build without the entitlement (built
//   from source, or the command line) everything works as in 0.5 and nothing is sent anywhere.
// - The later edit wins, key by key: each synced key goes to iCloud as {t: time of the edit, v: value}; a key with no v
//   was removed (Automatic language). A device takes iCloud's record when it is newer than its own last edit and sends
//   its own when that is newer. A value set in 0.5 has no edit time: the dictionary's is its last edit (0.5 kept it), the
//   others count as older than any edit, so a Mac updated from 0.5 joins what the person's other devices have.
// - Values from iCloud are checked for type and size before use: they come from the person's own devices, but one built
//   by somebody else from this source can write anything under the same team's store only if signed by this team, and a
//   broken value should cost nothing either way.
// - Apple's limits: 1 MB and 1024 keys for the whole store; a write over them fails there and stays here.
// Measured with the iPhone probe (2026-11-11): about 2 s each way; his iCloud quota unchanged to the byte.

import Foundation
#if os(macOS)
import Security
#endif

@MainActor final class Store {
    static let shared = Store()

    // The history setting joins these when history exists (stt-iphone.md, brief C).
    static let synced: Set<String> = ["language", "words", "replacements", "dictionaryChanged", "subtitles"]

    // Posted on the main thread after values came from iCloud; userInfo["keys"]: [String].
    static let changedFromCloud = Notification.Name("STTStoreChangedFromCloud")

    private let d = UserDefaults.standard
    private var cloud: NSUbiquitousKeyValueStore?
    private let timesKey = "syncTimes"   // when this device last edited, or took from iCloud, each synced key

    func object(_ key: String) -> Any? { d.object(forKey: key) }

    // nil removes the key.
    func set(_ value: Any?, _ key: String) {
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        guard Store.synced.contains(key) else { return }
        let t = Date().timeIntervalSince1970
        setTime(t, key)
        send(key, t)
    }

    // At launch, before the windows read their settings. A build without the entitlement never touches iCloud.
    func start() {
        guard cloud == nil, Store.mayUseCloud else { return }
        let c = NSUbiquitousKeyValueStore.default
        cloud = c
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: c, queue: .main) { n in
            let keys = n.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self.merge(keys.map(Set.init) ?? Store.synced) }
        }
        c.synchronize()
        // A value from 0.5 gets its edit time written down before anything is taken from iCloud: the dictionary's comes from
        // dictionaryChanged, which the merge itself may replace with another device's (security review 2026-11-11).
        for key in Store.synced where times[key] == nil { if let t = localTime(key) { setTime(t, key) } }
        merge(Store.synced)
    }

    // MARK: the merge

    private var times: [String: Double] { d.dictionary(forKey: timesKey) as? [String: Double] ?? [:] }
    private func setTime(_ t: Double, _ key: String) { var all = times; all[key] = t; d.set(all, forKey: timesKey) }

    // A key set in 0.5 has no time of its own yet: the dictionary has the time of its last edit, the rest counts as
    // older than anything edited since.
    private func localTime(_ key: String) -> Double? {
        if let t = times[key] { return t }
        guard d.object(forKey: key) != nil else { return nil }
        if ["words", "replacements", "dictionaryChanged"].contains(key), let c = d.object(forKey: "dictionaryChanged") as? Date {
            return c.timeIntervalSince1970
        }
        return 0
    }

    private func merge(_ keys: Set<String>) {
        guard let cloud else { return }
        var taken: [String] = []
        for key in keys.intersection(Store.synced).sorted() {
            let mine = localTime(key)
            // A time far ahead (a device with its clock set wrong) would make every later edit lose to it: such a record is left.
            guard let record = cloud.dictionary(forKey: key), let t = record["t"] as? Double, t.isFinite, t < Store.latest else {
                if let mine { setTime(mine, key); send(key, mine) }   // the first device to have it
                continue
            }
            // Edited here later than iCloud's (offline, or a 0.5 dictionary edited after another device's): this one goes.
            if let mine, mine > t { setTime(mine, key); send(key, mine); continue }
            if times[key] == t { continue }
            let value = record["v"]
            guard value == nil || Store.valid(value!, key) else { continue }
            if !Store.same(value, d.object(forKey: key)) {
                if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
                taken.append(key)
            }
            setTime(t, key)
        }
        if !taken.isEmpty { NotificationCenter.default.post(name: Store.changedFromCloud, object: self, userInfo: ["keys": taken]) }
    }

    private func send(_ key: String, _ t: Double) {
        guard let cloud else { return }
        var record: [String: Any] = ["t": t]
        if let v = d.object(forKey: key) { record["v"] = v }
        cloud.set(record, forKey: key)
        cloud.synchronize()
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a as NSObject, b as NSObject): return a.isEqual(b)
        default: return false
        }
    }

    static var latest: Double { Date().timeIntervalSince1970 + 86400 }

    // What each key may hold, and how much: far above any real dictionary (his has 34 words), far below iCloud's 1 MB.
    static func valid(_ v: Any, _ key: String) -> Bool {
        // No control or direction-changing characters: these strings end up in pasted text.
        func text(_ s: String, _ max: Int) -> Bool {
            s.unicodeScalars.count <= max && !s.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
            }
        }
        switch key {
        case "language": return (v as? String).map { $0.count <= 16 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") } } ?? false
        case "words": return (v as? [String]).map { $0.count <= 2000 && $0.allSatisfy { text($0, 200) } } ?? false
        case "replacements": return (v as? [[String]]).map { $0.count <= 5000 && $0.allSatisfy { $0.count == 2 && $0.allSatisfy { text($0, 200) } } } ?? false
        case "dictionaryChanged": return (v as? Date).map { $0.timeIntervalSince1970 < latest } ?? false
        case "subtitles": return v is Bool
        default: return false
        }
    }

    // iCloud key-value storage needs its entitlement, which only a build signed by the team with its provisioning
    // profile carries; without it the store would only log errors. The iPhone app is always built with it.
    static var mayUseCloud: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) != nil
        #else
        return true
        #endif
    }
}
