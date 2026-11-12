// The dictionary (0.4): words a model should write as they are spelled here, and replacements a person writes for what
// a model keeps getting wrong. Measured 2026-11-10 on the author's 199 dictations: with only the built-in names 78 % of
// names came out right; names outside the list failed (Handy 7 of 13, GigaAM 0 of 4); with his own words in Whisper's
// prompt 80 %, exactly those words fixed (13 of 13, 4 of 4), nothing invented, the rest of the text unchanged.
// - Words go into Whisper's prompt and Qwen's system message. Parakeet takes no hints in this engine, which the window says.
// - Replacements («клод» → «Claude») work on the text of any model, after recognition. Only what a person wrote: guessing
//   sound-alikes from the word list fixed names but turned about 40 ordinary words into names («прочитай» → «Parakeet»).

import Foundation

// Names many people say and models spell wrongly unless they have seen them (0.5, research of 2026-11-10 night): the 16 of
// 0.4 without iPhone and WhatsApp, which Whisper writes right alone, plus ten. Order is priority: when the prompt is full
// the last ones stay out, and a person's own words go before these. 24, not more: on the author's 199 dictations 16 and 24
// both gave 78 / 77 % of names right without pairs, 92 % with them; on other voices 24 did better (Ukrainian and Russian
// 54 → 59 % of the listed names) and changed no other word beyond run-to-run noise on 2 300 public clips; 32 gained
// nothing, and 42 (0.4's measurement) made it worse, since every extra name in Whisper's prompt weakens the others.
let presetWords = [
    "ChatGPT", "Claude", "Claude Code", "Anthropic", "OpenAI", "Gemini", "Google", "YouTube", "TikTok", "Instagram", "Telegram", "Facebook", "GitHub", "macOS", "MacBook", "Viber", "Zoom", "Perplexity", "DeepSeek", "Copilot", "Cursor", "Python", "ElevenLabs", "NotebookLM"]

// Replacements built in (0.5): how a model writes a name heard in Russian or Ukrainian, and the name. 104 pairs for 69
// names, each heard form checked against the author's speech and public sets so that no ordinary word is one («тему» is
// Temu 27 times in his speech, so it is not here; nor сигнал, зум, хром, курсор, сафари, сора…). With them Whisper
// wrote 92 % of the names in his dictations right instead of 78 %, Parakeet 72 % instead of 41 %. The person's table
// starts with them and can drop or restore them, as the words.
let presetPairs: [(heard: String, written: String)] = [
    ("клод", "Claude"), ("клод код", "Claude Code"), ("чат джипити", "ChatGPT"), ("чат джи пи ти", "ChatGPT"),
    ("чатджипити", "ChatGPT"), ("антропик", "Anthropic"), ("антропік", "Anthropic"), ("опен эй ай", "OpenAI"),
    ("опен ей ай", "OpenAI"), ("джемини", "Gemini"), ("джеміні", "Gemini"), ("гугл", "Google"),
    ("гмейл", "Gmail"), ("джимейл", "Gmail"), ("ютуб", "YouTube"), ("тикток", "TikTok"),
    ("тік ток", "TikTok"), ("тікток", "TikTok"), ("тик ток", "TikTok"), ("инстаграм", "Instagram"),
    ("інстаграм", "Instagram"), ("телеграм", "Telegram"), ("ватсап", "WhatsApp"), ("вотсап", "WhatsApp"),
    ("вацап", "WhatsApp"), ("фейсбук", "Facebook"), ("гитхаб", "GitHub"), ("гітхаб", "GitHub"),
    ("айфон", "iPhone"), ("айпад", "iPad"), ("макбук", "MacBook"), ("айклауд", "iCloud"),
    ("дипсик", "DeepSeek"), ("діпсік", "DeepSeek"), ("перплексити", "Perplexity"), ("перплексіті", "Perplexity"),
    ("миджорни", "Midjourney"), ("міджорні", "Midjourney"), ("вайбер", "Viber"), ("дискорд", "Discord"),
    ("діскорд", "Discord"), ("реддит", "Reddit"), ("редит", "Reddit"), ("реддіт", "Reddit"),
    ("пинтерест", "Pinterest"), ("пінтерест", "Pinterest"), ("линкедин", "LinkedIn"), ("лінкедін", "LinkedIn"),
    ("нетфликс", "Netflix"), ("нетфлікс", "Netflix"), ("спотифай", "Spotify"), ("спотіфай", "Spotify"),
    ("ноушн", "Notion"), ("фигма", "Figma"), ("фігма", "Figma"), ("дропбокс", "Dropbox"),
    ("пейпал", "PayPal"), ("пэйпал", "PayPal"), ("бинанс", "Binance"), ("бінанс", "Binance"),
    ("алиэкспресс", "AliExpress"), ("аліекспрес", "AliExpress"), ("виндовс", "Windows"), ("віндовс", "Windows"),
    ("эксель", "Excel"), ("ексель", "Excel"), ("пауэрпоинт", "PowerPoint"), ("пауерпоінт", "PowerPoint"),
    ("аутлук", "Outlook"), ("майкрософт", "Microsoft"), ("андроид", "Android"), ("андроїд", "Android"),
    ("линукс", "Linux"), ("лінукс", "Linux"), ("пайтон", "Python"), ("докер", "Docker"),
    ("хоумбрю", "Homebrew"), ("клаудфлэр", "Cloudflare"), ("клаудфлер", "Cloudflare"), ("маркдаун", "Markdown"),
    ("слак", "Slack"), ("тимс", "Teams"), ("грок", "Grok"), ("копайлот", "Copilot"),
    ("мистраль", "Mistral"), ("тредс", "Threads"), ("твич", "Twitch"), ("амазон", "Amazon"),
    ("фейстайм", "FaceTime"), ("снэпчат", "Snapchat"), ("снепчат", "Snapchat"), ("трелло", "Trello"),
    ("джира", "Jira"), ("глово", "Glovo"), ("револют", "Revolut"), ("самсунг", "Samsung"),
    ("сяоми", "Xiaomi"), ("вайлдберриз", "Wildberries"), ("гугл докс", "Google Docs"), ("гугл драйв", "Google Drive"),
    ("гугл мапс", "Google Maps"), ("гугл мит", "Google Meet"), ("гугл міт", "Google Meet"), ("чат gpt", "ChatGPT"),
]

// Stored as plain arrays under keys meant to stay as they are, and since 0.6 synced through iCloud with the person's other
// devices (store.swift): the later edit wins.
@MainActor enum Words {
    static let wordsKey = "words", replacementsKey = "replacements", changedKey = "dictionaryChanged"   // nosemgrep (names of settings keys, not secrets)
    static var onChange: (() -> Void)?
    private static func changed() { Store.shared.set(Date(), changedKey); onChange?() }

    // Never edited: the preset. Edited: exactly what the person left, the preset ones they kept included.
    static var words: [String] {
        get { UserDefaults.standard.stringArray(forKey: wordsKey) ?? presetWords }
        set {
            let v = clean(newValue)
            guard v != words || UserDefaults.standard.stringArray(forKey: wordsKey) == nil && v != presetWords else { return }
            Store.shared.set(v, wordsKey); changed()
        }
    }

    // Never edited: the built-in pairs. Edited: exactly the rows the person left.
    static var replacements: [(heard: String, written: String)] {
        get {
            guard let stored = UserDefaults.standard.array(forKey: replacementsKey) as? [[String]] else { return presetPairs }
            return stored.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        }
        set {
            let v = newValue.map { [$0.heard, $0.written] }
            let stored = UserDefaults.standard.array(forKey: replacementsKey) != nil
            guard v != replacements.map({ [$0.heard, $0.written] }) || !stored && v != presetPairs.map({ [$0.heard, $0.written] }) else { return }
            Store.shared.set(v, replacementsKey); changed()
        }
    }

    static var missingPairs: [(heard: String, written: String)] {
        let have = Set(replacements.map { $0.heard.lowercased() })
        return presetPairs.filter { !have.contains($0.heard.lowercased()) }
    }

    // The built-in pairs that were removed come back at the end; the person's rows stay as they are.
    static func restorePairs() { replacements = replacements + missingPairs }

    static var missingPreset: [String] {
        let have = Set(words.map { $0.lowercased() })
        return presetWords.filter { !have.contains($0.lowercased()) }
    }

    // The preset words that were removed come back where they were; the person's own words stay first.
    static func restore() { words = words + missingPreset }

    // Trimmed, no empty ones, no repeats (the first spelling wins).
    static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

// The person's replacements on finished text: the heard form as a whole word, any case; a Cyrillic one also with the
// Russian and Ukrainian case endings after it («клода», «клоду» → «Claude»), since a written name doesn't decline. Several
// words match with any spaces or hyphens between them. A sentence that began with the heard form keeps its capital.
func replace(_ text: String, _ pairs: [(heard: String, written: String)]) -> String {
    var s = text
    let ends = "(?:ами|ями|ові|еві|ом|ем|ой|ей|ах|ях|ам|ям|ов|ів|а|у|е|ы|и|і|ю|я|о)?"
    for (heard, written) in pairs.sorted(by: { $0.heard.count > $1.heard.count }) {
        let parts = heard.split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty, !written.isEmpty else { continue }
        let cyrillic = heard.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let pattern = "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "[\\s-]+") + (cyrillic ? ends : "") + "(?![\\p{L}\\p{N}])"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
        for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            var w = written
            if s[r].first?.isUppercase == true, w.first?.isLowercase == true {
                let before = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if before.isEmpty || ".?!…".contains(before.last!) { w = w.prefix(1).uppercased() + w.dropFirst() }
            }
            s.replaceSubrange(r, with: w)
        }
    }
    return s
}
