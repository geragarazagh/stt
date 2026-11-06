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

// Names people say that Whisper spells wrongly unless it has seen them. On 198 real dictations: Claude 0 > 16, ChatGPT 0 > 3,
// GitHub 20 > 53; nothing invented in sentences that don't mention them. The engine's own vocabulary option refuses to
// work beside a prompt, so they go first in the prompt, and only in the languages where they were measured not to hurt.
let names = "ChatGPT, Claude, Claude Code, Anthropic, OpenAI, Gemini, Google, YouTube, TikTok, Instagram, Telegram, WhatsApp, Facebook, GitHub, iPhone, macOS. "
nonisolated(unsafe) var nameLanguages: Set<String> = ["ru", "uk", "en", "de", "fr", "es", "nl", "tr", "ro", "pl", "sv", "vi", "ja"]

// Everything the native library touches runs on one serial queue: a session is single-threaded.
final class Engine: @unchecked Sendable {
    let queue = DispatchQueue(label: "engine", qos: .userInitiated)
    private var model: Model?
    private var session: Session?
    private var vadModel: Model?
    private var vad: VadSession?

    private var isWhisper = false
    private var language: String?
    var forced: String?   // the language chosen in the window; nil lets the model detect it

    // Whisper only. Without an example of punctuation it often writes long runs of speech with none at all, and the
    // end of the text so far keeps the grammar going across a cut.
    private func options(_ hints: String, after text: String) -> RunOptions {
        guard isWhisper else { return RunOptions(language: forced) }
        return RunOptions(language: forced, family: .whisper(WhisperRunOptions(initialPrompt: hints + " " + text.suffix(200))))
    }

    private func hints(_ code: String?) -> String {
        guard let code else { return "" }
        return (nameLanguages.contains(code) ? names : "") + (punctuationExamples[code] ?? "")
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
    }

    // The native side asserts at exit when a Metal resource is still alive, so everything is let go first.
    func release() { session = nil; model = nil; vad = nil; vadModel = nil }

    func unload() { session = nil; model = nil }

    // `shouldGoOn` is asked between pieces, for long files: it gets the share done and false stops the job.
    func transcribe(_ pcm: [Float], shouldGoOn: ((Double) -> Bool)? = nil) throws -> String {
        guard let session else { throw Failure.noModel }
        var text = ""
        let all = try pieces(pcm)
        for (i, piece) in all.enumerated() {
            if let shouldGoOn, !shouldGoOn(Double(i) / Double(all.count)) { throw Failure.stopped }
            // People mostly stay in one language, so the last one is tried first and a second run happens only on a change.
            var hint = hints(forced ?? language)
            var run = try session.run(piece, options: options(hint, after: text))
            if isWhisper, forced == nil, i == 0, run.language != language {
                language = run.language
                let found = hints(language)
                if found != hint {
                    hint = found
                    run = try session.run(piece, options: options(hint, after: text))
                }
            }
            var t = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Every piece comes back as if it opened a sentence. Inside a sentence it doesn't, and Latin names keep their capital.
            if let last = text.last, !".?!…".contains(last), let first = t.first, first.isUppercase, first.isCyrillic {
                t = first.lowercased() + t.dropFirst()
            }
            if !t.isEmpty { text += (text.isEmpty ? "" : " ") + t }
        }
        return clean(text)
    }

    // Speech only, in pieces of at most about 30 s, cut at pauses. A pause inside a piece is kept up to 0.3 s.
    private func pieces(_ pcm: [Float]) throws -> [[Float]] {
        guard let vad else { return [pcm] }
        let rate = 16000, target = 30 * rate, gap = rate * 3 / 10
        let found = try vad.run(pcm, options: VadOptions(minSilenceMs: 300, speechPadMs: 120, maxSpeechMs: 30000)).segments
        var out: [[Float]] = [], cur: [Float] = []
        for s in found {
            let a = max(0, Int(s.startSample)), b = min(pcm.count, Int(s.endSample))
            guard b > a else { continue }
            if !cur.isEmpty && cur.count + (b - a) > target { out.append(cur); cur = [] }
            if !cur.isEmpty { cur += [Float](repeating: 0, count: gap) }
            cur += pcm[a..<b]
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

private extension Character {
    var isCyrillic: Bool { unicodeScalars.first.map { (0x0400...0x04FF).contains($0.value) } ?? false }
}

enum Failure: Error { case noModel, stopped, noSound }

// Filler sounds only, never words: «э-э-э», «ммм», «uh». Some models write them down faithfully.
private let filler = try! NSRegularExpression(pattern:
    "(?<![\\p{L}\\p{N}-])(э+(-э+)*|эм+|м-м+|мм+|хм+|uh+|uhm+|umm+|ehm+|ahm+)(?![\\p{L}\\p{N}-])[,.…]?", options: .caseInsensitive)

func clean(_ text: String) -> String {
    var s = filler.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    for (a, b) in [("  +", " "), (" ([,.?!…])", "$1"), (",([,.?!])", "$1"), ("^[ ,.]+", ""), (" +$", "")] {
        s = s.replacingOccurrences(of: a, with: b, options: .regularExpression)
    }
    // A filler that opened the text took the capital with it.
    if text.first?.isUppercase == true, let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
    return s
}

