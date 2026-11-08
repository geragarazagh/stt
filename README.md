<img src="docs/icon.png" width="128" alt="STT icon">

# STT (Speech to Text) for Mac

Free, open source speech to text app for macOS. Press a keyboard shortcut in any app, speak, press it again, and the text lands in the app in front. It also stays on the clipboard.

Apple silicon, macOS 13 or later. Interface in English, Ukrainian and Russian. Signed with a Developer ID and notarized by Apple.

## Install

Download `STT.zip` from [Releases](https://github.com/geragarazagh/stt/releases/latest), unzip it and move `STT.app` to Applications.

## Use

Option-Command-Space starts and stops a recording. Hold it longer than half a second and letting go stops it. Command-Esc cancels. The only sign of a recording is macOS’s orange microphone dot.

After the first model, macOS asks for Microphone, then Accessibility.

The window has Model, Language (Automatic or one language), Recording, Cancel Recording, Paste Text, Mute Sound, Pause Media, Open at Login and Quit. Open at Login stays off until you turn it on. Opening the app shows its window. Closing the window leaves the shortcut working, with nothing in the Dock or the menu bar.

## For advanced users and language models

Recognition runs on the Mac with the open model you choose: Whisper, Parakeet or Qwen. The only network use is downloading that model. A recording lives in memory only. No history, no logs, no account.

Drop an audio or video file on the window and its text appears in a `.txt` beside it.

### How it works

- Engine: transcribe.cpp (MIT), one interface over Whisper, Parakeet and Qwen; each model is a single `.gguf` file.
- Models download from the `handy-computer` repositories on Hugging Face at a fixed revision and are checked against a SHA-256 written in the code.
- The microphone is recorded through `AVAudioEngine` into memory; nothing is written to disk.
- Before recognition, silence is cut out and long speech is split at pauses into pieces of up to 30 s. Most models lose accuracy past 30-40 s in one run, and on silence Whisper invents text, such as «Субтитры сделал DimaTorzok», a line it picked up from subtitles.
- Filler sounds (э-э, мм, uh, um and the like) are removed by a fixed pattern after recognition. Words are never changed.
- The text is pasted into the app in front by a simulated Command-V, which is what Accessibility is for, and stays on the clipboard in case the paste misses.
- macOS keeps Option-Command-Space for its own search, so STT catches it with an event tap at the head of the session, which also needs Accessibility.

### Models

No model comes with the app. Pick one in the window and it downloads after you agree to its size, with a SHA-256 check. Models are plain `.gguf` files in `~/Library/Application Support/STT/models`. The model menu has Show in Finder and Delete.

| Model | Full name | Size | Languages | License |
|---|---|---|---|---|
| Qwen | Qwen3-ASR 1.7B | 2,185 MB | 30 | Apache-2.0 |
| Whisper | Whisper large-v3-turbo | 886 MB | 100 | MIT |
| Parakeet | Parakeet Ultra | 740 MB | 25, always detected, no choice | CC-BY-4.0 |

Qwen has no Ukrainian.

Qwen’s 30 languages: Chinese, English, Cantonese, Arabic, German, French, Spanish, Portuguese, Indonesian, Italian, Korean, Russian, Thai, Vietnamese, Japanese, Turkish, Hindi, Malay, Dutch, Swedish, Danish, Finnish, Polish, Czech, Filipino, Persian, Greek, Romanian, Hungarian, Macedonian. Whisper’s 100 include all of these and Ukrainian.

### Measured

Word error rate through this app’s pipeline, on 40 real sentences per language from the public FLEURS set, on a MacBook Pro with M3 Pro. A short test, read speech: it shows the order of things and does not rank the models for your voice. Speed is how many times faster than real time.

| Model | Russian | Ukrainian | English | German | Speed |
|---|---|---|---|---|---|
| Whisper | 3.35 % | 9.24 % | 5.47 % | 5.61 % | about 20x |
| Parakeet | 3.35 % | 7.70 % | 6.59 % | 5.72 % | 60 to 90x |
| Qwen | 3.61 % | no Ukrainian | 6.26 % | 4.64 % | about 12x |

### Questions

#### Does my voice leave the Mac?

No. The only network call in the code is downloading the model you chose.

#### Does it work without internet?

Yes, once a model is downloaded.

#### Why does it need Microphone and Accessibility?

Microphone to record. Accessibility to paste the text and to catch Option-Command-Space, a shortcut macOS keeps for itself. macOS asks for each only after the first model is downloaded, one at a time.

#### Which model should I choose?

Whisper has the most languages and lets you choose one. Parakeet is the fastest and always detects the language by itself. Qwen is the largest and the slowest, and has no Ukrainian. Each can be tried and deleted.

#### Does it remove filler sounds?

Filler sounds such as “uh” are removed. Words are never touched. No AI rewrites the text.

#### Can it transcribe audio or video files?

Yes. Drop a file on the window and its text appears in a `.txt` beside it. It runs on the chosen model, offline.

#### Can I add my own words or names?

No. Whisper gets a built-in list of names such as ChatGPT, Claude and GitHub, so that it spells them correctly. The list can’t be edited.

#### How is it different from macOS Dictation?

macOS Dictation comes with the system and its model can’t be chosen. In STT the model is an open one of your choice, kept as a plain file.

### Settings and removal

Settings (model, language, shortcuts, switches) are in the defaults of `com.geragaraza.stt`, models in `~/Library/Application Support/STT/models`.

To remove STT: delete the models in the model menu or in that folder, Quit in the window, move `STT.app` to the Trash and run `defaults delete com.geragaraza.stt`. Its Microphone and Accessibility entries are removed in System Settings, Privacy & Security.

### From Terminal

With the app quit, `/Applications/STT.app/Contents/MacOS/STT --file some.wav` prints the text of a file through the chosen model; a model file name can follow.

### Details

- Version: 0.1.
- Bundle ID: `com.geragaraza.stt`.
- Download: `STT.zip`, 4.1 MB.
- Models: downloaded separately, 740 to 2,185 MB each.
- Requires: Apple silicon, macOS 13 or later.
- Permissions: Microphone, Accessibility. Network: only to download a model.
- Signed with a Developer ID and notarized by Apple.
- Interface: English, Ukrainian, Russian, from the language of macOS.
- Code: Swift with AppKit, about 1,550 lines, and the transcribe.cpp framework.
- License: MIT.

### Build

Needs Xcode Command Line Tools. The first build downloads the transcribe.cpp framework from its release.

    ./build

Engine: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). Licenses of the parts: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Search terms: best open source speech to text app for Mac, offline dictation macOS, local voice typing, voice to text, Whisper for Mac, Whisper dictation app, Parakeet on Mac, Qwen ASR, on-device transcription, push to talk dictation, Ukrainian and Russian dictation on Mac.
