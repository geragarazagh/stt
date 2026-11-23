// The command line (0.5): the app's own binary, run under the name stt-cli (Homebrew links it so; by hand:
// ln -s /Applications/STT.app/Contents/MacOS/STT /usr/local/bin/stt-cli), or as STT with these arguments:
//
//   stt-cli FILE...                              each file's text to standard output, with the model, language and dictionary set in the app
//   stt-cli --srt FILE...                        the same as subtitles (SubRip)
//   stt-cli --toggle                             starts or stops a recording in the running app, as its key does
//   stt-cli --add-word WORD                      adds a word to the dictionary of the running app (dictionary.swift, Words.add)
//   stt-cli --remove-word WORD                   removes a word from the dictionary of the running app
//   stt-cli --add-pair HEARD WRITTEN             adds a replacement: what a model writes, and what to write instead
//   stt-cli --remove-pair HEARD                  removes a replacement from the dictionary of the running app
//   stt-cli --list-words [--json]                prints every word in the dictionary
//   stt-cli --list-pairs [--json]                prints every replacement pair (heard<Tab>written)
//   stt-cli --history [N] [--search Q] [--json]  prints recent dictations from History.sqlite
//   stt-cli --status [--json]                    prints active model, language, running state, dictionary and history counts
//   stt-cli --version                            prints app name and version
//
// Why stt-cli and not stt: a plain `stt` is taken on many Macs by speech tools of its own (the author's own Mac among them),
// and Homebrew has an unrelated «sttr».
//
// Files are read and transcribed in this process, with the rights of whoever ran it, never through the app: a program that
// can't read a file can't get its text this way. --toggle does go through the app, since the recording and the paste
// belong to it; the app then records with its own microphone permission. So it asks two things first (security pass
// 2026-11-10): the caller must be this same signed binary (the app checks the code signature of the other end of the
// socket, so posting a notification or writing to the socket from elsewhere does nothing), and the program that ran it
// must hold the microphone permission itself (macOS answers that for the responsible program, Terminal for a person
// typing): a program the person never allowed the microphone can't record through STT.
// The dictionary commands (2026-11-15, for agents that keep a person's dictionary) also go through the app and not into the
// settings file: the running app would not see a `defaults write` until it relaunched, and the edit must reach its other
// devices through iCloud with its time (store.swift), which only the signed app can do. The same signature check holds;
// no microphone check, since a word in a list records nothing. Any program of the person's could already write the
// settings file itself, so the socket gives none of them more than they had; the app checks every word as it checks a
// value from iCloud.
// Both hold only while someone else is the responsible program. Launched as an app (`open -n -a STT --args …`), as a launchd
// job, or with responsibility disclaimed, this process answers for itself and would read files and use the microphone with
// the app's own permissions (security pass 2026-11-10, both hunters): every command-line mode refuses to run then.

import AppKit
import AVFoundation
import Security

let cliName = "stt-cli"

// Resolve the enclosing .app bundle even when invoked through a symlink (/opt/homebrew/bin/stt-cli -> STT.app/Contents/MacOS/STT).
// Without this, Bundle.main points to /opt/homebrew/bin, bundleIdentifier is nil, and UserDefaults.standard reads the wrong domain.
let cliAppBundle: Bundle = {
    // executableURL, not argv[0]: run by name from PATH (the Homebrew symlink) argv[0] is the bare name, and the bundle
    // three levels above it is the current folder's, not the app's (measured 2026-11-23: version 0, settings unread).
    let real = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

// Run from inside the bundle the process is the app itself: a suite named after its own id is refused (nil, and a
// console line «will not work» on every run), and .standard is that domain already. Through a symlink Bundle.main has
// no id, so the suite is what reaches the app's settings.
private var cliDefaults: UserDefaults {
    guard let id = cliAppBundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return .standard }
    return UserDefaults(suiteName: id) ?? .standard
}

// The app's socket: in the user's own Darwin temp folder (0700, per user, via confstr so a shell or agent harness that
// overrides TMPDIR still finds the running GUI app's socket), named by the bundle so a test build has its own.
var controlPath: String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let dir = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 ? String(cString: buf) : NSTemporaryDirectory()
    let base = dir.hasSuffix("/") ? dir : dir + "/"
    return base + (cliAppBundle.bundleIdentifier ?? "com.geragaraza.stt") + ".sock"
}

private func unixAddress(_ path: String) -> sockaddr_un {
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: a.sun_path) - 1))
    withUnsafeMutableBytes(of: &a.sun_path) { dst in for (i, b) in bytes.enumerated() { dst[i] = b } }
    return a
}

// True when macOS counts this process as its own responsible program (its permissions are STT's own). The lookup is libsystem's
// responsibility_get_pid_responsible_for_pid, unexported in headers but present since macOS 10.14; without it, a parent of
// launchd (a launch by LaunchServices or launchd) counts as the same.
func answersForItself() -> Bool {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    let me = getpid()
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {   // RTLD_DEFAULT
        let r = unsafeBitCast(f, to: Lookup.self)(me)
        if r > 0 { return r == me }
    }
    return getppid() == 1
}

private func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

// Called first in main: true when this run is the command line. A run under another name with no arguments prints the usage
// instead of starting a second copy of the app.
@MainActor func runCommandLine(_ args: [String]) -> Bool {
    let named = URL(fileURLWithPath: args[0]).lastPathComponent != (cliAppBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "STT")
    let rest = Array(args.dropFirst())
    let usage = """
    Usage: \(cliName) [--srt] FILE...                              prints the text of each audio or video file
           \(cliName) --toggle                                     starts or stops a recording in STT
           \(cliName) --add-word WORD                              adds a name or term to STT's dictionary, spelled as it should be written
           \(cliName) --remove-word WORD                           removes a word from STT's dictionary
           \(cliName) --add-pair HEARD WRITTEN                     adds a replacement: what the model writes, and what to write instead
           \(cliName) --remove-pair HEARD                          removes a replacement from STT's dictionary
           \(cliName) --list-words [--json]                        prints every word in the dictionary
           \(cliName) --list-pairs [--json]                        prints every replacement pair (heard<Tab>written)
           \(cliName) --history [N] [--search QUERY] [--json]      prints recent dictations (default 20)
           \(cliName) --status [--json]                            prints active model, language, running state and counts
           \(cliName) --version                                    prints app version
    """
    // Which mode, if any; the app itself (no arguments, or its own --login, --background, --pasteboard) goes on.
    var run: (() -> Never)?
    switch rest.first {
    case "--toggle": run = rest.count == 1 ? { toggle() } : { fail(usage) }
    case "--add-word": run = rest.count == 2 ? { ask(["add-word", rest[1]]) } : { fail(usage) }
    case "--remove-word": run = rest.count == 2 ? { ask(["remove-word", rest[1]]) } : { fail(usage) }
    case "--add-pair": run = rest.count == 3 ? { ask(["add-pair", rest[1], rest[2]]) } : { fail(usage) }
    case "--remove-pair": run = rest.count == 2 ? { ask(["remove-pair", rest[1]]) } : { fail(usage) }
    case "--list-words": run = { listWords(Array(rest.dropFirst()), usage: usage) }
    case "--list-pairs": run = { listPairs(Array(rest.dropFirst()), usage: usage) }
    case "--history": run = { listHistory(Array(rest.dropFirst()), usage: usage) }
    case "--status": run = { printStatus(Array(rest.dropFirst()), usage: usage) }
    case "--version", "-V":
        let v = cliAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let n = cliAppBundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "STT"
        print("\(n) \(v)"); exit(0)
    case "--srt": run = { transcribeFromCommandLine(rest) }
    case "--help", "-h": print(usage); exit(0)
    case nil: if named { print(usage); exit(0) }
    case let a? where !a.hasPrefix("-"):
        // Under its own name STT takes a file only when it exists, so nothing a system passes at launch is read as one.
        if named || FileManager.default.fileExists(atPath: a) { run = { transcribeFromCommandLine(rest) } }
    // An unknown --word under its own name too (2026-11-15: `STT --version` started a second copy, which showed its window and
    // took the running app's socket over). The app's own: --login, --background, --pasteboard; macOS's are one dash (-psn_…).
    case let a?: if named || a.hasPrefix("--") && !["--login", "--background", "--pasteboard"].contains(a) { fail(usage) }
    }
    guard let run else { return false }
    if answersForItself() {
        fail("\(cliName) runs from a terminal or a script. Started as an app or a launchd job it would act with STT’s own permissions.")
    }
    run()
    return false
}

private func printJSON(_ obj: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { fail("Could not encode JSON.") }
    print(text)
    exit(0)
}

@MainActor private func listWords(_ args: [String], usage: String) -> Never {
    let json = args == ["--json"]
    guard args.isEmpty || json else { fail(usage) }
    let raw = cliDefaults.stringArray(forKey: Words.wordsKey) ?? presetWords
    let list = raw.map(printable)
    if json { printJSON(list) }
    for w in list { print(w) }
    exit(0)
}

@MainActor private func listPairs(_ args: [String], usage: String) -> Never {
    let json = args == ["--json"]
    guard args.isEmpty || json else { fail(usage) }
    let pairs: [(heard: String, written: String)]
    if let stored = cliDefaults.array(forKey: Words.replacementsKey) as? [[String]] {
        pairs = stored.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    } else {
        pairs = presetPairs
    }
    let rows = pairs.map { (heard: printable($0.heard), written: printable($0.written)) }
    if json { printJSON(rows.map { [$0.heard, $0.written] }) }
    for r in rows { print("\(r.heard)\t\(r.written)") }
    exit(0)
}

@MainActor private func listHistory(_ args: [String], usage: String) -> Never {
    var limit = 20, query: String? = nil, json = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--json": json = true; i += 1
        case "--search":
            guard i + 1 < args.count else { fail(usage) }
            query = args[i + 1]; i += 2
        default:
            guard let n = Int(args[i]), n > 0, i == 0 else { fail(usage) }
            limit = n; i += 1
        }
    }
    var rows = History.shared.all()
    if let q = query, !q.isEmpty {
        rows = rows.filter { ($0.text ?? "").localizedCaseInsensitiveContains(q) }
    }
    let slice = Array(rows.prefix(limit))
    let fmt = ISO8601DateFormatter()
    if json {
        let out: [[String: Any]] = slice.map { r in
            var d: [String: Any] = [
                "id": r.id?.uuidString ?? "",
                "created": r.created.map { fmt.string(from: $0) } ?? "",
                "duration": NSDecimalNumber(value: Int((r.duration * 10).rounded())).dividing(by: NSDecimalNumber(value: 10)),
                "model": printable(r.model ?? ""),
                "text": printable(r.text ?? ""),
            ]
            if let lang = r.language { d["language"] = printable(lang) }
            if let audio = r.audioURL?.path { d["audio"] = audio }
            return d
        }
        printJSON(out)
    }
    for r in slice {
        let ts = r.created.map { fmt.string(from: $0) } ?? ""
        let dur = String(format: "%.1fs", r.duration)
        let text = printable(r.text ?? "").replacingOccurrences(of: "\n", with: " ")
        print("\(ts)\t\(dur)\t\(text)")
    }
    exit(0)
}

private func isRunning() -> Bool {
    guard let id = cliAppBundle.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
}

@MainActor private func printStatus(_ args: [String], usage: String) -> Never {
    let json = args == ["--json"]
    guard args.isEmpty || json else { fail(usage) }
    let version = cliAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let activeId = cliDefaults.string(forKey: "model")
    let active = models.first { $0.id == activeId && $0.isHere }?.id
    let downloaded = models.filter(\.isHere).map(\.id)
    let language = cliDefaults.string(forKey: "language") ?? "auto"
    let keep = Keep(cliDefaults.string(forKey: Keep.key)).string
    let running = isRunning()
    let wordCount = (cliDefaults.stringArray(forKey: Words.wordsKey) ?? presetWords).count
    let pairCount = (cliDefaults.array(forKey: Words.replacementsKey) as? [[String]])?.filter { $0.count == 2 }.count ?? presetPairs.count
    let historyCount = History.shared.all().count
    if json {
        printJSON([
            "version": version,
            "running": running,
            "model": active as Any,
            "downloadedModels": downloaded,
            "language": language,
            "historyKeep": keep,
            "words": wordCount,
            "pairs": pairCount,
            "historyCount": historyCount,
            "modelsDir": modelsFolder.path,
            "historyDir": historyFolder.path,
        ])
    }
    print("version: \(version)")
    print("running: \(running ? "yes" : "no")")
    print("model: \(active ?? "none")")
    print("downloaded: \(downloaded.isEmpty ? "none" : downloaded.joined(separator: ", "))")
    print("language: \(language)")
    print("historyKeep: \(keep)")
    print("dictionary: \(wordCount) words, \(pairCount) pairs")
    print("history: \(historyCount) recordings")
    exit(0)
}

@MainActor private func transcribeFromCommandLine(_ rest: [String]) -> Never {
    let subtitles = rest.first == "--srt"
    let paths = subtitles ? Array(rest.dropFirst()) : rest
    guard !paths.isEmpty else { fail("No file given.") }
    guard let m = models.first(where: { $0.id == cliDefaults.string(forKey: "model") && $0.isHere }) ?? models.first(where: { $0.isHere })
    else { fail("No model: choose one in the STT window first.") }
    let e = Engine()
    do { try e.load(path: m.path.path, vadPath: cliAppBundle.path(forResource: "silero-vad-v6.2-F32", ofType: "gguf")) } catch { fail("\(m.title): \(error)") }
    // The language and the dictionary as the app has them.
    let all = cliDefaults.stringArray(forKey: Words.wordsKey) ?? presetWords, preset = Set(presetWords.map { $0.lowercased() })
    e.ownWords = all.filter { !preset.contains($0.lowercased()) }
    e.builtIn = all.filter { preset.contains($0.lowercased()) }
    if let stored = cliDefaults.array(forKey: Words.replacementsKey) as? [[String]] {
        e.pairs = stored.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    } else {
        e.pairs = presetPairs
    }
    if let code = cliDefaults.string(forKey: "language"), m.languages.contains(code) { e.forced = code }
    var failed = false
    for (i, path) in paths.enumerated() {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            failed = true; FileHandle.standardError.write("\(path): No such file or no permission to read it\n".data(using: .utf8)!); continue
        }
        do {
            let r = try e.transcribeTimed(try readMedia(url))
            if paths.count > 1 { print((i > 0 ? "\n" : "") + "==> \(path) <==") }
            print(subtitles ? srt(r.cues) : r.text)
            fflush(stdout)   // in order with the errors on standard error
        } catch Failure.noSound {
            failed = true; FileHandle.standardError.write("\(path): Can’t read sound from this file\n".data(using: .utf8)!)
        } catch {
            failed = true; FileHandle.standardError.write("\(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
    e.release()
    exit(failed ? 1 : 0)
}

private func toggle() -> Never {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: break
    case .notDetermined:
        let done = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
        if done.wait(timeout: .now() + 120) == .timedOut || !granted { fail("No access to the microphone for the program that ran \(cliName).") }
    default: fail("No access to the microphone for the program that ran \(cliName). It is given in System Settings > Privacy & Security > Microphone.")
    }
    send("toggle\n")
}

// A dictionary command, as one line of JSON: the words may hold any character but a newline, and the app refuses those.
private func ask(_ command: [String]) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: command), data.count < 4000 else { fail("Too long.") }
    send(String(decoding: data, as: UTF8.self) + "\n", edit: true)
}

// The answer: "ok", or "ok " and what was done (printed), or an error (printed on standard error, exit 1).
private func send(_ line: String, edit: Bool = false) -> Never {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
    var a = unixAddress(controlPath)
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    // An agent can start it without a window: open -g -a STT --args --background
    guard ok else { fail("STT is not running.") }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    let answer = readSocket(fd, limit: 4096, seconds: 10, toNewline: false)
    close(fd)
    // Through printable() like any text STT hands on (engine.swift): the answer repeats the word it was given, and goes to a
    // terminal or an agent's log.
    let text = printable(String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    if text == "ok" { exit(0) }
    if text.hasPrefix("ok ") { print(text.dropFirst(3)); exit(0) }
    // 0.8 and before know only --toggle.
    if edit && text == "Unknown command." { fail("This STT has no dictionary commands yet: update it (Check for Updates in its Settings).") }
    fail(text.isEmpty ? "STT did not answer." : text)
}

// BEGIN readSocket (tests/socket-deadline compiles this block on its own)
// Reads up to `limit` bytes, to the end of the stream or (toNewline) the first newline, within `seconds` IN ALL: a timeout
// per read alone (SO_RCVTIMEO, what this was before security pass 4) lets a sender that trickles a byte a little under
// the timeout hold the reader as long as it likes, and on the app's side the reader is the main thread with the key tap.
func readSocket(_ fd: Int32, limit: Int, seconds: Double, toNewline: Bool) -> Data {
    let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
    var data = Data(), buf = [UInt8](repeating: 0, count: 1024)
    while data.count < limit, !(toNewline && data.last == 10) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { break }
        let left = end - now
        // Never 0 and 0: that timeval means no timeout at all.
        var t = timeval(tv_sec: Int(left / 1_000_000_000), tv_usec: Int32(max(1, (left % 1_000_000_000) / 1000)))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        let n = read(fd, &buf, min(buf.count, limit - data.count))
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    return data
}
// END readSocket

// The app's side: one command per connection, taken only from this same binary, signed as the app is.
@MainActor final class Control {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var requirement: SecRequirement?
    private var inode: ino_t = 0
    var toggle: () -> String = { "ok" }   // the answer: "ok" or an error to print
    var edit: ([String]) -> String = { _ in "Unknown command." }   // a dictionary command: "ok …" or an error

    func start() {
        var me: SecCode?, staticMe: SecStaticCode?, req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess else { return }
        requirement = req
        let path = controlPath
        unlink(path)   // a socket left by a crash; a second copy of the same app takes it over
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var a = unixAddress(path)
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        var st = stat()
        guard bound, chmod(path, 0o600) == 0, listen(fd, 4) == 0, lstat(path, &st) == 0 else { close(fd); fd = -1; unlink(path); return }
        inode = st.st_ino
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel(); source = nil
        // Only our own socket: another copy of the app may have taken the path over since.
        var st = stat()
        if fd >= 0 { close(fd); fd = -1; if lstat(controlPath, &st) == 0, st.st_ino == inode { unlink(controlPath) } }
    }

    private func accept() {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return }
        defer { close(c) }
        // Prevent SIGPIPE from killing the running app if a peer disconnects before reading the reply.
        var noSigPipe: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // The peer is checked before anything is read, so a stranger can't hold the main thread (and the key tap on it).
        guard trusted(c) else { _ = "Refused: not \(cliName).\n".withCString { write(c, $0, strlen($0)) }; return }
        // One line, at most 4 KB, read within a second in all, so a slow sender holds nothing for long.
        let line = readSocket(c, limit: 4096, seconds: 1, toNewline: true)
        let reply: String
        if line == Data("toggle\n".utf8) { reply = toggle() }
        else if line.last == 10, let words = (try? JSONSerialization.jsonObject(with: line)) as? [String], !words.isEmpty { reply = edit(words) }
        else { reply = "Unknown command." }
        _ = (reply + "\n").withCString { write(c, $0, strlen($0)) }
    }

    // The other end must be this app's own code: its audit token, checked against the app's designated requirement.
    private func trusted(_ c: Int32) -> Bool {
        var token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(c, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0, let requirement else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
