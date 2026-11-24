---
name: stt
description: "Transcribes audio or video files offline, toggles dictation, maintains the user's speech-to-text dictionary, and reads dictation history using STT for Mac (stt-cli). Use when transcribing local media, fixing recurring dictation mishearings, searching past dictations, or customizing STT."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with STT installed (brew install geragarazagh/tap/stt or /Applications/STT.app)."
---

# STT

Drives the macOS STT app (`stt-cli`) for offline transcription, dictation dictionary upkeep, history search, and local customization.

## Locate the CLI

Check in order; use the first that exits 0:

```sh
stt-cli --version
/Applications/STT.app/Contents/MacOS/STT --version
```

If neither exists, tell the user how to install it (`brew install geragarazagh/tap/stt`) and stop. Never invent a transcript.

## Common tasks

1. **Transcribe files** (uses the model, language, and dictionary configured in STT):
   ```sh
   stt-cli path/to/audio.m4a
   stt-cli --srt path/to/video.mp4 > video.srt
   ```
2. **Check status** (active model, downloaded models, language, running state, counts):
   ```sh
   stt-cli --status
   stt-cli --status --json
   ```
3. **Maintain the dictionary** (edits sync to iPhone via iCloud and reload live; requires STT running — start silently with `open -g -a STT --args --background` if needed):
   ```sh
   stt-cli --list-words
   stt-cli --list-pairs
   stt-cli --add-word "Cloudflare"
   stt-cli --add-pair "клаудфлер" "Cloudflare"
   stt-cli --remove-word "OldTerm"
   stt-cli --remove-pair "oldheard"
   ```
4. **Search dictation history**:
   ```sh
   stt-cli --history 20
   stt-cli --history 50 --search "invoice" --json
   ```
5. **Toggle live dictation**:
   ```sh
   stt-cli --toggle
   ```

## Dictionary hygiene rules

- **Words (`--add-word`)** feed Whisper's initial prompt and Qwen's vocabulary. Keep the personal list concise (~10–30 high-frequency names/terms); too many words dilute Whisper's prompt. Parakeet ignores the word list and uses replacements only.
- **Replacements (`--add-pair HEARD WRITTEN`)** run after recognition on every model and match Russian/Ukrainian case endings on Cyrillic heard forms automatically (`гитхаба` → `GitHub`).
- Never add a heard form that is also an ordinary word in the user's language (for example `тему` or `сигнал`), or it will corrupt normal sentences.
- When you spot a recurring unambiguous mishearing in the user's dictated messages, inspect `--list-pairs` first so you do not duplicate an existing rule, then add it or confirm once if ambiguous.

## Open storage & rebuilding from source

- Models: `~/Library/Application Support/STT/models/` (GGUF files).
- History: `~/Library/Application Support/STT/History/` (`History.sqlite` + `<uuid>.m4a`).
- Preferences: `defaults read com.geragaraza.stt`.
- Source & rebuild: clone `https://github.com/geragarazagh/stt`, read `AGENTS.md`, edit Swift files, and run `./build` (needs full Xcode: STT's SwiftUI macros are not in Command Line Tools).
