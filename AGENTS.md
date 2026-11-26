# AGENTS.md — STT

Offline macOS speech-to-text app in plain Swift (AppKit, SwiftUI, Core Data, `transcribe.cpp`). No Xcode project; `./build` compiles everything directly with `swiftc`.

## Architecture

- `shared/engine.swift` — Silero VAD + `transcribe.cpp` inference, Whisper prompt token budgeting, stall/garbage re-decode, subtitle-credit & filler filters, `printable()`.
- `shared/dictionary.swift` — built-in `presetWords` (24) and `presetPairs` (104), `Words` storage + `add`/`remove` validation (`Words.problem`), case-aware Cyrillic replacement engine `replace()`.
- `shared/store.swift` — `UserDefaults` + last-writer-wins `NSUbiquitousKeyValueStore` iCloud sync (`language`, `words`, `replacements`, `dictionaryChanged`, `subtitles`, `historyKeep`).
- `shared/history.swift` — Core Data `History.sqlite` + 16 kHz mono AAC `<uuid>.m4a` files in `~/Library/Application Support/STT/History/`.
- `shared/models.swift` — pinned GGUF models (Whisper, Parakeet; retired ones deleted at launch) with SHA-256 and Hugging Face revision hashes.
- `shared/intents.swift` — Shortcuts App Intents (`Record`, `Start`, `Stop`, `Transcribe File`).
- `mac/entry.swift` — `App` delegate, `AVAudioEngine` recorder (with `notBluetooth()`), session `CGEventTap` hot key, delivery (`Paste Text` / `Copy Text` / `borrowClipboard`), file queue.
- `mac/cli.swift` — `stt-cli` CLI entry point + `Control` per-user `0600` Unix socket (`$TMPDIR/<bundle-id>.sock`) with `LOCAL_PEERTOKEN` designated-requirement verification and 1 s read deadline (`readSocket`).
- `mac/main-window.swift`, `mac/window.swift`, `mac/dictionary-window.swift`, `mac/files.swift` — History, Settings, Dictionary, and Files windows.
- `mac/icon.swift` — procedural 11-bar waveform icon generator.

## Build & Test

- `./build` — builds ad-hoc signed `STT.app` (Apple Silicon, `-target arm64-apple-macos13.0`). Needs full Xcode in `/Applications/Xcode.app` (or `XCODE_CONTENTS`): the SwiftUI windows use macros whose plugin ships only with Xcode, so Command Line Tools alone cannot build STT.
- `TEST=1 ./build` — builds isolated `STT Test.app` (`com.geragaraza.stt.test`) with its own defaults, socket, and history folder. Always delete `STT Test.app` before running a release script.
- `tests/socket-deadline` — unit test for `readSocket` total-deadline enforcement (needs no app).
- `tests/synced-dictionary` — unit test for `Store.valid` / `Words.problem` validation.
- `tests/dictionary-command "STT Test.app"` — end-to-end CLI test against a running test copy.

## Invariants

- **Security**: every CLI mode checks `answersForItself()` (`responsibility_get_pid_responsible_for_pid`) and refuses execution when launched as its own responsible app/launchd job. Live dictionary edits and `--toggle` go over the `0600` Unix socket verified by `LOCAL_PEERTOKEN`. Every string returned to stdout/pasteboard passes `printable()`.
- **Offline**: zero network calls except user-confirmed model downloads (SHA-256 verified) and Sparkle update checks.
- **Vendor integrity**: `./build` verifies `treesha` of `vendor/CTranscribe.framework` and `vendor/Sparkle.framework` on every build.
- **English-only UI**: `CFBundleLocalizations = [en]`; `L()` returns its English key.
- **Customizing locally**: edit source, run `./build`, replace `/Applications/STT.app`. Note: changing from Developer ID to an ad-hoc signature makes macOS re-ask Microphone and Accessibility permissions (`tccutil reset All com.geragaraza.stt` if stuck).
