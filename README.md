<picture><source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png"><img src="docs/icon.png" width="128" alt="STT icon"></picture>

# STT (Speech to Text) for Mac

Free, open source speech to text app for macOS. Press a keyboard shortcut in any app, speak, press it again, and the text lands in the app in front. It also stays on the clipboard.

Apple silicon, macOS 13 or later. Interface in English, Ukrainian and Russian. Signed with a Developer ID and notarized by Apple.

![STT in use: Leo Tolstoy's phonograph recordings of 1908-1909 in Russian, French, English and German in STT's history, the letter he dictated on 9 April 1908 open as STT heard it, unedited, the player at 0:33, where «смертной казни» (the death penalty) is heard as «смерти металли», and Settings beside it, dark appearance](docs/scene.webp)

## Install

**Mac** (Apple silicon, macOS 13 or later): download [`STT.dmg`](https://github.com/geragarazagh/stt/releases/latest/download/STT.dmg) (4.4 MB), open it and drag `STT.app` to Applications. Later versions arrive through Check for Updates.

Or with [Homebrew](https://brew.sh):

```sh
brew install geragarazagh/tap/stt
```

## Use

Option-Command-Space starts and stops a recording. Hold it longer than half a second and letting go stops it. Command-Esc cancels. With the window closed, the only sign of a recording is macOS’s orange microphone dot; in the window the recording shows under the list with its time and waveform.

After the first model, macOS asks for Microphone, then Accessibility.

The window is the list of dictations, newest first: each keeps its text, which can be edited in place, and its audio, which can be played. Search goes through the texts; Copy Text, Share (the text or the audio), Transcribe Again with another model and Show in Finder are on the right click; Delete moves recordings to Recently Deleted for 30 days. Several are chosen with Command-A, Shift or Command-click. The record button under the list starts and stops a recording as the shortcut does, and a recording made there is not pasted into the window. Settings (Command-comma) has Check for Updates; Model and Language (Automatic or one language); Recording and Cancel Recording; Open at Login; Pause Media and Mute Sound; Paste Text; Transcribe File with Choose File…; Save Subtitles (.srt); Dictionary with Edit…; History; Quit. Open at Login stays off until it is turned on. Opening the app shows its window. While the window is open, STT is in the Dock and the menu bar like any app; closing the window leaves the shortcut working, with nothing in the Dock or the menu bar.

## For advanced users and language models

Recognition runs on the Mac with an open model of choice: Whisper, Parakeet or Qwen. The network is used only to download that model and to check for updates; language, dictionary, the subtitles switch and the history setting also go through iCloud to the other Macs of the same account. Each recording is kept with its text on the Mac (History, below). No logs, no account of its own.

Audio and video files: Choose File… in Settings, File › Transcribe File… (Command-O), a drop anywhere on either window, or Open With → STT in Finder. The text is saved beside the file as a `.txt` with the same name (`Interview.m4a` gives `Interview.txt`; an existing file is never overwritten, the new one is `Interview (2).txt`) and copied to the clipboard; it is not pasted. A small window shows the progress with Cancel, then the name of the `.txt`, which shows it in Finder when clicked. Several files go one after another, each to its own `.txt`; a dictation made meanwhile waits for the file. With Save Subtitles (.srt) on, an `.srt` with timecodes goes beside the `.txt` under the same name (`Interview.srt`), one subtitle per stretch of speech the model marks. Files opened by another program than Finder or the Dock (`open -a STT` in Terminal, a script) are asked about first, since their text goes to the clipboard.

### History

Each dictation is kept with its audio in `~/Library/Application Support/STT/History`: one store with the texts and one AAC file per recording, about 256 KB a minute. History in Settings keeps all, 30 days (the default), 7 days, the last 100, or none; a choice that would erase recordings asks once, with their number. Delete moves a recording to Recently Deleted for 30 days, where Recover brings it back and Delete Forever erases it with its audio. Transcribe Again runs the kept audio through any downloaded model and replaces the text. A text that a password field kept off the clipboard is not kept either.

### How it works

- Engine: transcribe.cpp (MIT), one interface over Whisper, Parakeet and Qwen; each model is a single `.gguf` file.
- Models download from the `handy-computer` repositories on Hugging Face at a fixed revision and are checked against a SHA-256 written in the code.
- The microphone is recorded through `AVAudioEngine` into memory; once the text is made, the audio goes to History (below) unless History is set to Don’t Keep. The recording goes on 0.3 s after the stop, so the last word isn’t cut. A Bluetooth headset is not used as the microphone, since that drops its sound to call quality: the Mac’s own microphone is taken instead, unless there is no other.
- Words from Dictionary go first in Whisper’s prompt, fitted to its 223 tokens with the model’s own tokenizer so the punctuation example and the text so far keep their place, and into Qwen’s system message. On 199 real dictations the words added to Dictionary went from 0-54 % written right to all of them, with nothing invented, and the built-in pairs raised the names written right from 78 % to 92 % with Whisper and from 41 % to 72 % with Parakeet.
- Before recognition, silence is cut out and long speech is split at pauses into pieces of up to 30 s. Most models lose accuracy past 30-40 s in one run.
- On silence and at the end of speech Whisper writes lines it learned from film subtitles, such as «Субтитры сделал DimaTorzok» or «Продолжение следует...». Such credit lines are removed when they close a piece of speech.
- Whisper Turbo sometimes stops after a few words (a short «Vielen Dank.» for fifteen seconds of a speech) or loops one phrase. Such a piece is transcribed again without the prompt and then, if still short, at temperature 0.2, and the fuller text is kept. On European Parliament speeches this took German from 22.9 % to 16.1 % of wrong words and Dutch from 22.8 % to 12.4 %; nothing got worse.
- Filler sounds are removed by a fixed pattern after recognition: э-э, ммм, хм, uh, hmm, äh, euh, yyy and the like, and um in English only (in German and Portuguese it is a word). Words are never changed.
- The text is pasted into the app in front by a simulated Command-V, which is what Accessibility is for, and stays on the clipboard in case the paste misses. While a password field is active (macOS’s Secure Input), the text is neither pasted nor put on the clipboard.
- macOS keeps Option-Command-Space for its own search, so STT catches it with an event tap at the head of the session, which also needs Accessibility.

### Models

No model comes with the app. One is chosen in Settings and downloads after its size is confirmed, with a SHA-256 check. Models are plain `.gguf` files in `~/Library/Application Support/STT/models`. The model menu has Show in Finder and Delete.

| Model | Full name | Size | Languages | License |
|---|---|---|---|---|
| Qwen | Qwen3-ASR 1.7B | 2,185 MB | 30 | Apache-2.0 |
| Whisper | Whisper large-v3-turbo | 886 MB | 100 | MIT |
| Parakeet | Parakeet Ultra | 740 MB | 25, always detected, no choice | CC-BY-4.0 |

Qwen has no Ukrainian.

Qwen’s 30 languages: Chinese, English, Cantonese, Arabic, German, French, Spanish, Portuguese, Indonesian, Italian, Korean, Russian, Thai, Vietnamese, Japanese, Turkish, Hindi, Malay, Dutch, Swedish, Danish, Finnish, Polish, Czech, Filipino, Persian, Greek, Romanian, Hungarian, Macedonian. Whisper’s 100 include all of these and Ukrainian.

### Measured

Word error rate through this app’s pipeline, on 40 real sentences per language from the public FLEURS set, on a MacBook Pro with M3 Pro. A short test, read speech: it shows the order of things and does not rank the models for any one voice. Speed is how many times faster than real time.

| Model | Russian | Ukrainian | English | German | Speed |
|---|---|---|---|---|---|
| Whisper | 3.35 % | 9.24 % | 5.47 % | 5.61 % | about 20x |
| Parakeet | 3.35 % | 7.70 % | 6.59 % | 5.72 % | 60 to 90x |
| Qwen | 3.61 % | no Ukrainian | 6.26 % | 4.64 % | about 12x |

Other people’s spontaneous speech: speeches in the European Parliament (VoxPopuli), one utterance from each of 40 speakers per language, through this app’s pipeline. Word error rate:

| Model | Czech | German | English | Spanish | French | Italian | Dutch | Polish |
|---|---|---|---|---|---|---|---|---|
| Parakeet | 10.8 % | 9.6 % | 8.3 % | 6.5 % | 7.6 % | 12.1 % | 9.6 % | 9.1 % |
| Qwen | 21.6 % | 11.5 % | 9.9 % | 6.9 % | 9.0 % | 16.2 % | 11.3 % | 15.1 % |
| Whisper | 18.0 % | 16.1 % | 12.0 % | 6.7 % | 9.8 % | 20.6 % | 12.4 % | 14.7 % |

### Questions

#### Does the voice leave the Mac?

No. The code goes online only to download the chosen model and to check for updates, and iCloud carries four settings (below); recordings and their texts stay on the Mac.

#### Do the settings sync between Macs?

Yes, by themselves, with no switch: Language, the Dictionary (words and replacements), Save Subtitles (.srt) and History are the same on every Mac signed in to one iCloud account, through iCloud key-value storage; the later change wins. The model, the shortcuts and the other switches stay with each Mac, and so do the recordings themselves. Without iCloud everything works the same on that Mac alone.

#### Does it work without internet?

Yes, once a model is downloaded.

#### Why does it need Microphone and Accessibility?

Microphone to record. Accessibility to paste the text and to catch Option-Command-Space, a shortcut macOS keeps for itself. macOS asks for each only after the first model is downloaded, one at a time.

#### Which model to choose?

Parakeet made the fewest errors on other people’s speech in all eight languages measured and is the fastest; it always detects the language by itself. Whisper has the most languages and lets one be chosen. Qwen is the largest and the slowest and has no Ukrainian: it writes Ukrainian speech as a mixture of Russian and Polish words. Each can be tried and deleted.

#### Does it remove filler sounds?

Filler sounds such as “uh” are removed. Words are never touched. No AI rewrites the text.

#### Can it transcribe audio or video files?

Yes, offline, with the chosen model: Choose File… in Settings, File › Transcribe File…, a drop on a window, or Open With → STT in Finder. The text is saved beside the file as a `.txt` with the same name (and, with Save Subtitles (.srt) on, an `.srt` with timecodes) and copied to the clipboard. Several files at once give a `.txt` each. Shortcuts and the command line `stt-cli` do the same without the window.

#### Can words or names be added?

Yes, in Dictionary (Edit… in Settings). Words: names and terms written exactly as typed; Return adds one, Delete removes it, Restore brings back the 24 built-in ones (ChatGPT, Claude, GitHub and others). Whisper and Qwen take them; Parakeet takes no word list, and the window says so. Replacements: what a model writes and what to write instead, for every model, applied to the finished text; the table starts with 104 built-in pairs for names said in Russian or Ukrainian (клод → Claude, ютуб → YouTube), and its own Restore brings back removed ones. Command-V pastes into both; a list of lines «heard, Tab, written» pasted over the table becomes rows, and Delete removes the selected ones.

#### How is it different from macOS Dictation?

macOS Dictation comes with the system and its model can’t be chosen. In STT the model is an open one, chosen in Settings and kept as a plain file.

### Updates

Once a day the app reads the feed of its latest GitHub release (`appcast.xml`) through Sparkle. Nothing about the Mac is sent. When a newer version is out, a window shows it with Install Update, Remind Me Later and Skip This Version; nothing is downloaded before Install Update. Check for Updates, in the STT menu and in Settings, checks at once.

The feed and the disk image are signed with an EdDSA key, and Sparkle installs only an app that carries the same Developer ID signature.

### Settings and removal

Settings (model, language, shortcuts, switches, dictionary) and the time of the last update check are in the defaults of `com.geragaraza.stt`, models in `~/Library/Application Support/STT/models`, the history in `~/Library/Application Support/STT/History`. The four synced settings are also kept for the iCloud account by the key-value service of macOS; they take no iCloud storage.

To remove STT: Quit in Settings, delete the folder `~/Library/Application Support/STT` (models and history), move `STT.app` to the Trash and run `defaults delete com.geragaraza.stt`. Its Microphone and Accessibility entries are removed in System Settings, Privacy & Security.

Installed with Homebrew, `brew uninstall --zap stt` quits it and removes the app, its settings, the models and the history; the Microphone and Accessibility entries stay for System Settings.

### Shortcuts

STT adds four actions to the Shortcuts app: Record is one press of the shortcut key (it starts a recording, or stops it and gives the text to the next action); Start Recording and Stop Recording act as the shortcut key does (the text is pasted as usual, and Stop Recording also gives it to the next action), and Transcribe File gives the text of an audio or video file to the next action without saving a `.txt`. A shortcut made of them can go on a key, a schedule or an automation.

### Command line

Homebrew links the command `stt-cli`; with the disk image, `ln -s /Applications/STT.app/Contents/MacOS/STT /usr/local/bin/stt-cli` makes it. It uses the model, language and dictionary chosen in Settings.

```sh
stt-cli Interview.m4a > Interview.txt   # the text
stt-cli --srt Interview.m4a             # subtitles
stt-cli --toggle                        # start or stop a recording
```

Files are read with the rights of the program that runs the command, not the app’s. `--toggle` works the running app as its key does, and only for a program that has the Microphone permission itself (Terminal asks once). Started as an app or a launchd job rather than from a terminal or a script, the command refuses to run, since it would then act with STT’s own permissions.

### Details

- Version: 0.8.
- Bundle ID: `com.geragaraza.stt`.
- Download: `STT.dmg`, 4.4 MB.
- Models: downloaded separately, 740 to 2,185 MB each.
- Requires: Apple silicon, macOS 13 or later.
- Permissions: Microphone, Accessibility. Network: to download a model and to check for updates; iCloud for four settings.
- Signed with a Developer ID and notarized by Apple.
- Interface: English, Ukrainian, Russian, from the language of macOS.
- Code: Swift with AppKit, SwiftUI and Core Data, about 3,400 lines, the transcribe.cpp framework, and Sparkle for updates.
- License: MIT.

### Build

Needs Xcode 26 or later in Applications: the Swift compiler, and actool with Icon Composer for the light and dark icon. The first build downloads the transcribe.cpp and Sparkle frameworks from their releases. A build from source works the same without iCloud sync, which needs the author’s signature and provisioning profile.

    ./build

Engine: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). Updates: [Sparkle](https://sparkle-project.org). Licenses of the parts: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Search terms: best open source speech to text app for Mac, offline dictation macOS, local voice typing, voice to text, Whisper for Mac, Whisper dictation app, Parakeet on Mac, Qwen ASR, on-device transcription, push to talk dictation, Ukrainian and Russian dictation on Mac.
