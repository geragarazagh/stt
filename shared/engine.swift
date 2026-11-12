import Foundation

// MARK: engine

// Whisper writes in the manner of the text before it, so an example of punctuation helps only in the language being
// spoken: measured on 40 real sentences, a Russian example on Ukrainian speech took errors from 9.7 % to 16.7 %, and an
// English one on Russian from 3.2 % to 21.7 %. Whisper names the language after a first run with no example.
nonisolated(unsafe) var punctuationExamples = [
    "ru": "Привет, как дела? Всё хорошо, спасибо. Ну, давай.",
    "uk": "Привіт, як справи? Усе добре, дякую. Ну, давай.",
    "en": "Hello, how are you? I'm fine, thanks. Well, let's go.",
    // Added only where 40 real sentences came out better with it than without.
    "de": "Hallo, wie geht's? Mir geht's gut, danke. Na dann, los.",
    "fr": "Salut, ça va ? Oui, très bien, merci. Bon, allons-y.",
    "es": "Hola, ¿cómo estás? Muy bien, gracias. Bueno, vamos.",
    "it": "Ciao, come stai? Tutto bene, grazie. Allora, andiamo.",
    "nl": "Hallo, hoe gaat het? Goed, dank je. Nou, laten we gaan.",
    "tr": "Merhaba, nasılsın? İyiyim, teşekkürler. Hadi, gidelim.",
    "ro": "Salut, ce mai faci? Sunt bine, mulțumesc. Hai, să mergem.",
    "ja": "こんにちは、お元気ですか？はい、元気です、ありがとう。じゃあ、行きましょう。",
    "zh": "你好，最近怎么样？我很好，谢谢。好，我们走吧。",
    "ar": "مرحبا، كيف حالك؟ أنا بخير، شكرا. حسنا، هيا بنا.",
]

// The dictionary's words (dictionary.swift) go first in Whisper's prompt: on 198 real dictations the 16 built-in names
// took Claude 0 > 16, GitHub 20 > 53, nothing invented in sentences that don't mention them. The engine's own vocabulary
// option refuses to work beside a prompt, so they are written into it. The built-in ones only in the languages where
// they were measured not to hurt; a person's own words everywhere, since they put them there.
nonisolated(unsafe) var nameLanguages: Set<String> = ["ru", "uk", "en", "de", "fr", "es", "nl", "tr", "ro", "pl", "sv", "vi", "ja"]

// Whisper's prompt holds 223 tokens and, when longer, keeps its END: the words at its front would go first, silently.
// So the prompt is fitted here with the model's own tokenizer: the words that fit (a person's first, then the built-in
// ones in their order), the punctuation example always, then as much of the text so far as is left, at most 200
// characters. Measured: a 230-token list left no room and took ё from 732 to 124 and the commas with it.
let promptTokens = 220, contextTokens = 40   // 3 under the limit for the leading space; 40 ≈ 140 Russian letters of context

// Everything the native library touches runs on one serial queue: a session is single-threaded.
final class Engine: @unchecked Sendable {
    let queue = DispatchQueue(label: "engine", qos: .userInitiated)
    private var model: Model?
    private var session: Session?
    private var vadModel: Model?
    private var vad: VadSession?

    private var isWhisper = false, isQwen = false
    private var language: String?
    var forced: String?   // the language chosen in the window; nil lets the model detect it
    // The dictionary, copied in on the engine's queue: own words, then the built-in ones still kept, and the replacements.
    var ownWords: [String] = [], builtIn: [String] = [], pairs: [(heard: String, written: String)] = []

    // Whisper: the words, an example of punctuation (without one it often writes long runs of speech with none at all),
    // and the end of the text so far, which keeps the grammar going across a cut. Qwen: the words in its system message.
    private func options(_ code: String?, after text: String) -> RunOptions {
        if isQwen { return RunOptions(language: forced, vocabulary: ownWords + builtIn) }
        guard isWhisper else { return RunOptions(language: forced) }
        return RunOptions(language: forced, family: .whisper(WhisperRunOptions(initialPrompt: prompt(code, after: text))))
    }

    private func tokens(_ s: String) -> Int { (try? model?.tokenize(" " + s).count) ?? s.utf8.count / 2 }

    // Before the language is known (the first run of a dictation) the prompt is empty, as before the dictionary.
    func prompt(_ code: String?, after text: String) -> String {
        guard let code else { return "" }
        let example = punctuationExamples[code] ?? ""
        let words = ownWords + (nameLanguages.contains(code) ? builtIn : [])
        let tail = String(text.suffix(200))
        let room = promptTokens - min(tokens(tail), contextTokens)
        func head(_ n: Int) -> String { (n > 0 ? words.prefix(n).joined(separator: ", ") + ". " : "") + example }
        var lo = 0, hi = words.count   // the most words that fit, by halving: the token count grows with the number
        if tokens(head(hi)) > room {
            while hi - lo > 1 { let mid = (lo + hi) / 2; if tokens(head(mid)) <= room { lo = mid } else { hi = mid } }
            hi = lo
        }
        let fixed = head(hi)
        var context = tail
        while !context.isEmpty, tokens(fixed + " " + context) > promptTokens {
            context = String(context.dropFirst(max(1, context.count / 8)))
        }
        return context.isEmpty ? fixed : fixed + " " + context
    }

    func load(path: String, vadPath: String? = Bundle.main.path(forResource: "silero-vad-v6.2-F32", ofType: "gguf")) throws {
        session = nil; model = nil
        if vad == nil, let vadPath {
            vadModel = try Model(path: vadPath)
            vad = try vadModel!.vadSession()
        }
        model = try Model(path: path)
        session = try model!.session()
        isWhisper = model!.arch == "whisper"
        isQwen = model!.arch.hasPrefix("qwen")
    }

    // The native side asserts at exit when a Metal resource is still alive, so everything is let go first.
    func release() { session = nil; model = nil; vad = nil; vadModel = nil }

    func unload() { session = nil; model = nil }

    // `shouldGoOn` is asked between pieces, for long files: it gets the share done and false stops the job.
    func transcribe(_ pcm: [Float], shouldGoOn: ((Double) -> Bool)? = nil) throws -> String {
        try transcribeTimed(pcm, shouldGoOn: shouldGoOn).text
    }

    // The text, and the same speech as subtitle cues with times in the original sound (for the .srt beside a file). The
    // cues come from the model's own segments, moved back from the piece (silence cut out) to the file's time; a model
    // that gives no segment times gets one cue per piece.
    func transcribeTimed(_ pcm: [Float], shouldGoOn: ((Double) -> Bool)? = nil) throws -> (text: String, cues: [Cue]) {
        guard let session else { throw Failure.noModel }
        var text = "", spoken: String? = nil   // the language of the last piece, for the fillers that are words elsewhere
        var timed: [(start: Double, end: Double, text: String)] = []
        let all = try pieces(pcm)
        for (i, (piece, map)) in all.enumerated() {
            if let shouldGoOn, !shouldGoOn(Double(i) / Double(all.count)) { throw Failure.stopped }
            // People mostly stay in one language, so the last one is tried first and a second run happens only on a change.
            let hint = prompt(forced ?? language, after: text)
            var run = try session.run(piece, options: options(forced ?? language, after: text))
            if isWhisper, forced == nil, i == 0, run.language != language {
                language = run.language
                if prompt(language, after: text) != hint { run = try session.run(piece, options: options(language, after: text)) }
            }
            // Whisper Turbo sometimes stops after a few words: «Vielen Dank.» or «Grazie.» for fifteen seconds of a speech,
            // or loops one phrase. Measured on 320 parliament speeches in eight languages (VoxPopuli): 20 pieces. The same
            // sound started 1.5 s later came out whole, so it is the decoder, not the sound. Such a piece runs again without
            // the prompt, then, if still short, at temperature 0.2 with a fixed seed (Whisper's own way out of a stuck
            // decode; it brought back 3 of the 20, the plain rerun others). Another run's text is taken only when it is twice
            // as long and 20 letters longer, so a shorter honest answer never loses to an invented tail. Three letters a
            // second is a third of slow speech, and pauses are already cut.
            if isWhisper, piece.count >= 3 * 16000, collapsed(run.text, seconds: Double(piece.count) / 16000) {
                let calm = RunOptions(language: forced), warm = RunOptions(language: forced,
                    family: .whisper(WhisperRunOptions(temperature: 0.2, seed: 1)))
                for o in [calm, warm] {
                    let again = try session.run(piece, options: o)
                    if !looped(again.text), looped(run.text) || again.text.count >= max(2 * run.text.count, run.text.count + 20) { run = again }
                    if !collapsed(run.text, seconds: Double(piece.count) / 16000) { break }
                }
            }
            spoken = forced ?? run.language ?? language ?? spoken
            var t = dropCredits(run.text.trimmingCharacters(in: .whitespacesAndNewlines))
            // Every piece comes back as if it opened a sentence. Inside a sentence it doesn't, and Latin names keep their capital.
            if let last = text.last, !".?!…".contains(last), let first = t.first, first.isUppercase, first.isCyrillic {
                t = first.lowercased() + t.dropFirst()
            }
            if !t.isEmpty { text += (text.isEmpty ? "" : " ") + t }
            let segments = run.segments.filter { $0.t1Ms > $0.t0Ms && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if segments.isEmpty {
                if !t.isEmpty, let first = map.first, let last = map.last {
                    timed.append((Double(first.from) / 16000, Double(last.from + last.count) / 16000, t))
                }
            } else {
                for g in segments {
                    // ms to samples, kept inside the piece; a line break inside a cue would end it in the .srt
                    let at = { (ms: Int64) in self.original(Int(min(max(ms, 0), Int64(piece.count / 16))) * 16, map) }
                    timed.append((at(g.t0Ms), at(g.t1Ms), dropCredits(g.text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces))))
                }
            }
        }
        let cues = timed.map { Cue(start: $0.start, end: max($0.end, $0.start + 0.5), text: replace(clean($0.text, language: spoken), pairs)) }
            .filter { !$0.text.isEmpty }
        return (replace(clean(text, language: spoken), pairs), cues)
    }

    // A sample of a piece back to the sample of the original sound it came from (a pause between two stretches maps to
    // the end of the first).
    private func original(_ sample: Int, _ map: [Stretch]) -> Double {
        guard var best = map.first else { return 0 }
        for m in map where m.at <= sample { best = m }
        return Double(best.from + min(max(sample - best.at, 0), best.count)) / 16000
    }

    // Empty is not collapsed: over music or noise that got past the VAD an empty answer is the right one, and a run
    // without the prompt there is the one that invents («Thank you.» on 15 of 18 such clips, measured).
    private func collapsed(_ text: String, seconds: Double) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && Double(t.count) < 3 * seconds || looped(t)
    }

    // The same phrase of one to five words four times running: «Herr Präsident, Herr Präsident, Herr Präsident, ...».
    // Three is still speech («до конца, до конца, до конца», a coach on the last lap).
    private func looped(_ text: String) -> Bool {
        repeats.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // A stretch of speech inside a piece: where it starts in the piece, where it came from in the sound, how long it is.
    typealias Stretch = (at: Int, from: Int, count: Int)

    // Speech only, in pieces of at most about 30 s, cut at pauses. A pause inside a piece is kept up to 0.3 s.
    private func pieces(_ pcm: [Float]) throws -> [([Float], [Stretch])] {
        guard let vad else { return [(pcm, [(0, 0, pcm.count)])] }
        let rate = 16000, target = 30 * rate, gap = rate * 3 / 10
        let found = try vad.run(pcm, options: VadOptions(minSilenceMs: 300, speechPadMs: 120, maxSpeechMs: 30000)).segments
        var out: [([Float], [Stretch])] = [], cur: [Float] = [], map: [Stretch] = []
        for s in found {
            let a = max(0, Int(s.startSample)), b = min(pcm.count, Int(s.endSample))
            guard b > a else { continue }
            if !cur.isEmpty && cur.count + (b - a) > target { out.append((cur, map)); cur = []; map = [] }
            if !cur.isEmpty { cur += [Float](repeating: 0, count: gap) }
            map.append((cur.count, a, b - a))
            cur += pcm[a..<b]
        }
        if !cur.isEmpty { out.append((cur, map)) }
        return out
    }
}

private extension Character {
    var isCyrillic: Bool { unicodeScalars.first.map { (0x0400...0x04FF).contains($0.value) } ?? false }
}

enum Failure: Error { case noModel, stopped, noSound }

// One subtitle: seconds from the start of the file, and its text.
struct Cue { let start: Double, end: Double, text: String }

// SubRip, the subtitle format every player and editor reads: a number, «00:01:02,500 --> 00:01:05,000», the text, a blank line.
func srt(_ cues: [Cue]) -> String {
    func time(_ t: Double) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
    return cues.enumerated().map { "\($0.offset + 1)\n\(time($0.element.start)) --> \(time($0.element.end))\n\($0.element.text)\n" }
        .joined(separator: "\n")
}

private let repeats = try! NSRegularExpression(pattern: #"(?<!\w)((?:\w+[,.!?…]?\s+){0,4}\w+)(?:[,.!?…]?\s+\1(?!\w)){3,}"#,
                                               options: .caseInsensitive)

// Whisper learned from film subtitles to write their credits where the sound runs out: over noise, and as the last words
// of a piece of speech. Seen on other people's voice messages and once in his own dictation, always at the end of a piece:
// «Субтитры сделал DimaTorzok», «Продолжение следует...». Only lines nobody says are listed (subtitle credits in several
// languages, and «Продолжение следует», which closes a Russian series and never a dictation), and only at a piece's end.
private let credits = try! NSRegularExpression(pattern: [
    // a credit line that begins with its own words, also after a comma or a space
    #"(?:^|(?<=[\s,;:]))(?:Субтит(?:ры|ри)\s+(?:сделал|создавал|подогнал|делал|подготовил|зробив|створив)\b|Редактор\s+субтитров\b"#,
    #"|Untertitel(?:ung)?\s+(?:im\s+Auftrag|des\s+ZDF|der\s+Amara|von)\b|Sous-titr(?:es|age)\s+(?:réalisés|par|ST)\b)"#,
    #"(?:[^.!?…]|\.org|(?<=\b\p{Lu})\.)*[.!…]*\s*$"#,   // to the end; «.org» and the dot of an initial don't end it
    // a sentence naming the subtitle maker, in any language: no comma in it, so no words of the speaker go with it
    #"|(?:^|(?<=[.!?…]\s))(?:[^.!?…,]|\.org)*?(?:Amara\.org|DimaTorzok)(?:[^.!?…]|\.org)*[.!…]*\s*$"#,
    // the series ending, only as a sentence of its own with its capital
    #"|(?:^|(?<=[.!?…]\s))(?-i:Продолжение следует)[.!…]*\s*$"#,
].joined(), options: .caseInsensitive)

// The series ending also comes in the middle of a piece, with its capital and its dots, after a comma, a space or a word:
// «повторяем, да, Продолжение следует... Повтори круг» (3 times in the author's dictations, 2026-11-10). On 33 160 outputs
// of every model and test set this catches those 3 and nothing else; a person writing the words has no capital or no dots.
private let midCredit = try! NSRegularExpression(pattern: #"(?<=[,\s\p{L}])\s*Продолжение следует(?:\.\.\.|…)\s*"#)

func dropCredits(_ piece: String) -> String {
    let middle = midCredit.stringByReplacingMatches(in: piece, range: NSRange(piece.startIndex..., in: piece), withTemplate: " ")
    var s = credits.stringByReplacingMatches(in: middle, range: NSRange(middle.startIndex..., in: middle), withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
    // «...тренироваться, Субтитры сделал...»: the comma before the credit closed nothing; the speech ended there.
    if s.count < piece.count, let last = s.last, ",;:".contains(last) { s = s.dropLast() + "." }
    return s
}

// Filler sounds only, never words: «э-э-э», «ммм», «uh». Some models write them down faithfully. Each spelling here is a
// sound in every language the models know; «um» is a word in German and Portuguese («um 5 Uhr», «um carro»), so it goes
// only from English, and «мм» stays, since it is also «5 мм». Measured 2026-11-09: on 320 parliament speeches in eight
// languages and on everyday voice messages neither Whisper nor Parakeet wrote any filler; Qwen writes «А-а», «ам».
private let filler = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}-])(?:"#
    + #"э+(?:-э+)*|эм+|м-м+(?:-м+)*|м{3,}|хм+|гм+|е-е+(?:-е+)*|е{3,}"#            // ru, uk
    + #"|uh+|uhm+|umm+|ehm+|ahm+|hmm+|äh+m*|öh+m*|euh+|yyy+|eee+"#                  // en, de, fr, pl, it, es, nl
    + #")(?![\p{L}\p{N}-])[,.…]?"#, options: .caseInsensitive)
private let englishFiller = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}-])um+(?![\p{L}\p{N}-])[,.…]?"#, options: .caseInsensitive)

// A model's text goes straight into another app (pasted, a Shortcuts result, a .txt). Nothing a voice says is a control
// character: a newline, an escape or a direction change is the model's artefact, and pasted into a terminal a newline or
// an escape sequence (one that ends bracketed paste) could run a command. They become a space; Unicode's format
// characters that reorder text (bidi embedding, override, isolate) are dropped. Same rule as the synced dictionary.
func printable(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for u in text.unicodeScalars {
        switch u.value {
        case 0..<0x20, 0x7F...0x9F: out.append(" ")
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: continue
        default: out.append(u)
        }
    }
    return String(out)
}

func clean(_ text: String, language: String? = nil) -> String {
    var s = printable(text)
    for pattern in language == "en" ? [filler, englishFiller] : [filler] {
        // From the end, so the ranges before stay valid. A filler that closed a sentence leaves its full stop
        // («толщиной, м-м-м.» > «толщиной.»); one that opened a sentence hands its capital on («Ммм, да.» > «Да.»).
        for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            let found = s[r], before = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let opened = before.isEmpty || ".?!…".contains(before.last!), capital = found.first?.isUppercase == true
            s.replaceSubrange(r, with: !opened && found.last.map { ".…".contains($0) } == true ? String(found.last!) : "")
            if opened && capital, let next = s[r.lowerBound...].firstIndex(where: { $0.isLetter }), s[next].isLowercase {
                s.replaceSubrange(next...next, with: s[next].uppercased())
            }
        }
    }
    for (a, b) in [("  +", " "), (" ([,.?!…])", "$1"), (",([,.?!…])", "$1"), ("^[ ,.…]+", ""), (" +$", "")] {
        s = s.replacingOccurrences(of: a, with: b, options: .regularExpression)
    }
    return s
}

