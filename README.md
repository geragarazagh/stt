<picture><source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png"><img src="docs/icon.png" width="128" alt="STT icon"></picture>

# STT (Speech to Text) for Mac

Free, open source speech to text app for macOS. Press a keyboard shortcut in any app, speak, press it again, and the text lands in the app in front. It also stays on the clipboard.

Apple silicon, macOS 13 or later. Interface in English, Ukrainian and Russian. Signed with a Developer ID and notarized by Apple.

![STT in use: Leo Tolstoy's phonograph recordings of 1908-1909 in Russian, French, English and German, transcribed through Open With, a .txt beside each in Finder, and the letter he dictated on 9 April 1908 in TextEdit as STT heard it, unedited, dark appearance](docs/scene.webp)

## Install

Download `STT.dmg` from [Releases](https://github.com/geragarazagh/stt/releases/latest), open it and drag `STT.app` to Applications. Later versions arrive through Check for Updates.

Or with [Homebrew](https://brew.sh):

```sh
brew install geragarazagh/tap/stt
```

## Use

Option-Command-Space starts and stops a recording. Hold it longer than half a second and letting go stops it. Command-Esc cancels. The only sign of a recording is macOS’s orange microphone dot.

After the first model, macOS asks for Microphone, then Accessibility.

The window has Check for Updates; Model and Language (Automatic or one language); Recording and Cancel Recording; Open at Login; Pause Media and Mute Sound; Paste Text; Transcribe File with Choose File…; Dictionary with Edit…; Quit. Open at Login stays off until it is turned on. Opening the app shows its window. Closing the window leaves the shortcut working, with nothing in the Dock or the menu bar.

## For advanced users and language models

Recognition runs on the Mac with the open model you choose: Whisper, Parakeet or Qwen. The network is used only to download that model and to check for updates. A recording lives in memory only. No history, no logs, no account.

Audio and video files: Choose File… in the window, a drop anywhere on the window, or Open With → STT in Finder. The text is saved beside the file as a `.txt` with the same name (`Interview.m4a` gives `Interview.txt`; an existing file is never overwritten, the new one is `Interview (2).txt`) and copied to the clipboard; it is not pasted. A small window shows the progress with Cancel, then the name of the `.txt`, which shows it in Finder when clicked. Several files go one after another; a dictation made meanwhile waits for the file.

### How it works

- Engine: transcribe.cpp (MIT), one interface over Whisper, Parakeet and Qwen; each model is a single `.gguf` file.
- Models download from the `handy-computer` repositories on Hugging Face at a fixed revision and are checked against a SHA-256 written in the code.
- The microphone is recorded through `AVAudioEngine` into memory; nothing is written to disk. The recording goes on 0.3 s after the stop, so the last word isn’t cut. A Bluetooth headset is not used as the microphone, since that drops its sound to call quality: the Mac’s own microphone is taken instead, unless there is no other.
- Words from Dictionary go first in Whisper’s prompt, fitted to its 223 tokens with the model’s own tokenizer so the punctuation example and the text so far keep their place, and into Qwen’s system message. On 199 of the author’s dictations his own words took names written right from 78 % to 80 %, and the words he added from 0-54 % to all right; nothing was invented anywhere.
- Before recognition, silence is cut out and long speech is split at pauses into pieces of up to 30 s. Most models lose accuracy past 30-40 s in one run.
- On silence and at the end of speech Whisper writes lines it learned from film subtitles, such as «Субтитры сделал DimaTorzok» or «Продолжение следует...». Such credit lines are removed when they close a piece of speech.
- Whisper Turbo sometimes stops after a few words (a short «Vielen Dank.» for fifteen seconds of a speech) or loops one phrase. Such a piece is transcribed again without the prompt and then, if still short, at temperature 0.2, and the fuller text is kept. On European Parliament speeches this took German from 22.9 % to 16.1 % of wrong words and Dutch from 22.8 % to 12.4 %; nothing got worse.
- Filler sounds are removed by a fixed pattern after recognition: э-э, ммм, хм, uh, hmm, äh, euh, yyy and the like, and um in English only (in German and Portuguese it is a word). Words are never changed.
- The text is pasted into the app in front by a simulated Command-V, which is what Accessibility is for, and stays on the clipboard in case the paste misses. While a password field is active (macOS’s Secure Input), the text is neither pasted nor put on the clipboard.
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

Other people’s spontaneous speech: speeches in the European Parliament (VoxPopuli), one utterance from each of 40 speakers per language, through this app’s pipeline. Word error rate:

| Model | Czech | German | English | Spanish | French | Italian | Dutch | Polish |
|---|---|---|---|---|---|---|---|---|
| Parakeet | 10.8 % | 9.6 % | 8.3 % | 6.5 % | 7.6 % | 12.1 % | 9.6 % | 9.1 % |
| Qwen | 21.6 % | 11.5 % | 9.9 % | 6.9 % | 9.0 % | 16.2 % | 11.3 % | 15.1 % |
| Whisper | 18.0 % | 16.1 % | 12.0 % | 6.7 % | 9.8 % | 20.6 % | 12.4 % | 14.7 % |

### Questions

#### Does my voice leave the Mac?

No. The code goes online only to download the model you chose and to check for updates; a recording never leaves memory.

#### Does it work without internet?

Yes, once a model is downloaded.

#### Why does it need Microphone and Accessibility?

Microphone to record. Accessibility to paste the text and to catch Option-Command-Space, a shortcut macOS keeps for itself. macOS asks for each only after the first model is downloaded, one at a time.

#### Which model should I choose?

Parakeet made the fewest errors on other people’s speech in all eight languages measured and is the fastest; it always detects the language by itself. Whisper has the most languages and lets one be chosen. Qwen is the largest and the slowest and has no Ukrainian: it writes Ukrainian speech as a mixture of Russian and Polish words. Each can be tried and deleted.

#### Does it remove filler sounds?

Filler sounds such as “uh” are removed. Words are never touched. No AI rewrites the text.

#### Can it transcribe audio or video files?

Yes, offline, with the chosen model: Choose File… in the window, a drop on the window, or Open With → STT in Finder. The text is saved beside the file as a `.txt` with the same name and copied to the clipboard.

#### Can I add my own words or names?

Yes, in Dictionary (Edit… in the window). Words: names and terms written exactly as you type them; Return adds one, Delete removes it, Restore brings back the built-in ones (ChatGPT, Claude, GitHub and others). Whisper and Qwen take them; Parakeet takes no word list, and the window says so. Replacements: what a model writes and what to write instead (клод → Claude), for every model, applied to the finished text.

#### How is it different from macOS Dictation?

macOS Dictation comes with the system and its model can’t be chosen. In STT the model is an open one of your choice, kept as a plain file.

### Updates

Once a day the app reads the feed of its latest GitHub release (`appcast.xml`) through Sparkle, the usual open source updater for Mac apps. Nothing about the Mac is sent. When a newer version is out, a window shows it with Install Update, Remind Me Later and Skip This Version; nothing is downloaded before Install Update. Check for Updates in the window checks at once.

The feed and the disk image are signed with an EdDSA key, and Sparkle installs only an app that carries the same Developer ID signature.

### Settings and removal

Settings (model, language, shortcuts, switches, dictionary) and the time of the last update check are in the defaults of `com.geragaraza.stt`, models in `~/Library/Application Support/STT/models`.

To remove STT: delete the models in the model menu or in that folder, Quit in the window, move `STT.app` to the Trash and run `defaults delete com.geragaraza.stt`. Its Microphone and Accessibility entries are removed in System Settings, Privacy & Security.

Installed with Homebrew, `brew uninstall --zap stt` quits it and removes the app, its settings and the models; the Microphone and Accessibility entries stay for System Settings.

### From Terminal

With the app quit, `/Applications/STT.app/Contents/MacOS/STT --file some.wav` prints the text of a file through the chosen model; a model file name can follow.

### Details

- Version: 0.3.
- Bundle ID: `com.geragaraza.stt`.
- Download: `STT.dmg`, 4.2 MB.
- Models: downloaded separately, 740 to 2,185 MB each.
- Requires: Apple silicon, macOS 13 or later.
- Permissions: Microphone, Accessibility. Network: to download a model and to check for updates.
- Signed with a Developer ID and notarized by Apple.
- Interface: English, Ukrainian, Russian, from the language of macOS.
- Code: Swift with AppKit, about 2,100 lines, the transcribe.cpp framework, and Sparkle for updates.
- License: MIT.

### Build

Needs Xcode 26 or later in Applications: the Swift compiler, and actool with Icon Composer for the light and dark icon. The first build downloads the transcribe.cpp and Sparkle frameworks from their releases.

    ./build

Engine: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). Updates: [Sparkle](https://sparkle-project.org). Licenses of the parts: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Search terms: best open source speech to text app for Mac, offline dictation macOS, local voice typing, voice to text, Whisper for Mac, Whisper dictation app, Parakeet on Mac, Qwen ASR, on-device transcription, push to talk dictation, Ukrainian and Russian dictation on Mac.
