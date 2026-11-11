// What happens to the Mac's sound during a recording. Both are off until a person turns them on.
//
// Mute Sound is the output device's own mute, restored only if it was us who muted it.
//
// Pause Media: sending Pause and Play through MediaRemote (private, the only way that reaches any player without faking a
// key) works from an ordinary app; measured on macOS 27.2 with QuickTime and Safari. Asking whether something is playing
// doesn't: since macOS 15.4 the answer reaches only Apple's own programs, so playing.c asks from inside /usr/bin/perl, in
// about 50 ms. Play is sent only if something was playing before the Pause, or it would start what a person stopped.
// Without perl the fallback is Core Audio's list of processes sending sound out, which is public but keeps naming a player
// for about 9 s after it was paused (measured).

import CoreAudio
import Foundation

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ empty: T) -> T? {
    var a = address(selector, scope), value = empty, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
}

// MARK: mute

final class Mute {
    private var device: AudioObjectID?
    private let flag = "mutedByApp"   // survives a crash: the next launch gives the sound back

    private func set(_ d: AudioObjectID, _ on: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), v: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    private var output: AudioObjectID? { read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) }

    func on() {
        guard device == nil, let d = output,
              read(d, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0)) == 0, set(d, true) else { return }
        device = d
        UserDefaults.standard.set(true, forKey: flag)
    }

    func off() {
        guard let d = device else { return }
        _ = set(d, false)
        device = nil
        UserDefaults.standard.removeObject(forKey: flag)
    }

    func recoverAfterCrash() {
        guard UserDefaults.standard.bool(forKey: flag) else { return }
        if let d = output { _ = set(d, false) }
        UserDefaults.standard.removeObject(forKey: flag)
    }
}

// MARK: media

final class Media {
    private typealias Send = @convention(c) (Int32, CFDictionary?) -> Bool
    private let send: Send? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let s = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(s, to: Send.self)
    }()
    private var paused = false
    private let play: Int32 = 0, pause: Int32 = 1   // MRCommand

    private var somethingPlays: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", #"use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or exit 3; my $s = DynaLoader::dl_find_symbol($l, "stt_playing") or exit 3; DynaLoader::dl_install_xsub("main::p", $s); main::p();"#,
                       Bundle.main.path(forResource: "playing", ofType: "dylib") ?? ""]
        // An empty environment: perl runs code named by PERL5OPT and PERL5LIB, and its child would act with STT's
        // Microphone and Accessibility grants (security audit 2026-11-10). The script needs no variable.
        p.environment = [:]
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus <= 1 { return p.terminationStatus == 1 }
        } catch {}
        return somethingSounds
    }

    private var somethingSounds: Bool {
        var a = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.contains {
            read($0, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) == 1
                && read($0, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)) != me
        }
    }

    func stop() {
        guard !paused, somethingPlays else { return }
        paused = send?(pause, nil) == true
    }

    func resume() {
        guard paused else { return }
        paused = false
        _ = send?(play, nil)
    }
}
