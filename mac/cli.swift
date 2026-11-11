// The command line (0.5): the app's own binary, run under the name stt-cli (Homebrew links it so; by hand:
// ln -s /Applications/STT.app/Contents/MacOS/STT /usr/local/bin/stt-cli), or as STT with these arguments:
//
//   stt-cli FILE...         each file's text to standard output, with the model, language and dictionary set in the app
//   stt-cli --srt FILE...   the same as subtitles (SubRip)
//   stt-cli --toggle        starts or stops a recording in the running app, as its key does
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
// Both hold only while someone else is the responsible program. Launched as an app (`open -n -a STT --args …`), as a launchd
// job, or with responsibility disclaimed, this process answers for itself and would read files and use the microphone with
// the app's own permissions (security pass 2026-11-10, both hunters): every command-line mode refuses to run then.

import AppKit
import AVFoundation
import Security

let cliName = "stt-cli"

// The app's socket: in the user's own temporary folder (0700, per user), named by the bundle so a test build has its own.
var controlPath: String { NSTemporaryDirectory() + (Bundle.main.bundleIdentifier ?? "stt") + ".sock" }

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
    let named = URL(fileURLWithPath: args[0]).lastPathComponent != (Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "STT")
    let rest = Array(args.dropFirst())
    let usage = """
    Usage: \(cliName) [--srt] FILE...   prints the text of each audio or video file
           \(cliName) --toggle          starts or stops a recording in STT
    """
    // Which mode, if any; the app itself (no arguments, or its own --login, --background, --pasteboard) goes on.
    var run: (() -> Never)?
    switch rest.first {
    case "--toggle": run = rest.count == 1 ? { toggle() } : { fail(usage) }
    case "--srt": run = { transcribeFromCommandLine(rest) }
    case "--help", "-h": print(usage); exit(0)
    case nil: if named { print(usage); exit(0) }
    case let a? where !a.hasPrefix("-"):
        // Under its own name STT takes a file only when it exists, so nothing a system passes at launch is read as one.
        if named || FileManager.default.fileExists(atPath: a) { run = { transcribeFromCommandLine(rest) } }
    default: if named { fail(usage) }
    }
    guard let run else { return false }
    if answersForItself() {
        fail("\(cliName) runs from a terminal or a script. Started as an app or a launchd job it would act with STT’s own permissions.")
    }
    run()
    return false
}

@MainActor private func transcribeFromCommandLine(_ rest: [String]) -> Never {
    let subtitles = rest.first == "--srt"
    let paths = subtitles ? Array(rest.dropFirst()) : rest
    guard !paths.isEmpty else { fail("No file given.") }
    guard let m = models.first(where: { $0.id == UserDefaults.standard.string(forKey: "model") && $0.isHere }) ?? models.first(where: { $0.isHere })
    else { fail("No model: choose one in the STT window first.") }
    let e = Engine()
    do { try e.load(path: m.path.path) } catch { fail("\(m.title): \(error)") }
    // The language and the dictionary as the app has them.
    let all = Words.words, preset = Set(presetWords.map { $0.lowercased() })
    e.ownWords = all.filter { !preset.contains($0.lowercased()) }
    e.builtIn = all.filter { preset.contains($0.lowercased()) }
    e.pairs = Words.replacements
    if let code = UserDefaults.standard.string(forKey: "language"), m.languages.contains(code) { e.forced = code }
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
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
    var a = unixAddress(controlPath)
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    guard ok else { fail("STT is not running.") }
    var t = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    _ = "toggle\n".withCString { write(fd, $0, 7) }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = read(fd, &buf, buf.count)
    close(fd)
    let answer = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if answer == "ok" { exit(0) }
    fail(answer.isEmpty ? "STT did not answer." : answer)
}

// The app's side: one command per connection, taken only from this same binary, signed as the app is.
@MainActor final class Control {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var requirement: SecRequirement?
    private var inode: ino_t = 0
    var toggle: () -> String = { "ok" }   // the answer: "ok" or an error to print

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
        // The peer is checked before anything is read, so a stranger can't hold the main thread (and the key tap on it).
        guard trusted(c) else { _ = "Refused: not \(cliName).\n".withCString { write(c, $0, strlen($0)) }; return }
        var t = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(c, &buf, buf.count)
        let reply = n > 0 && String(decoding: buf[0..<n], as: UTF8.self) == "toggle\n" ? toggle() : "Unknown command."
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
