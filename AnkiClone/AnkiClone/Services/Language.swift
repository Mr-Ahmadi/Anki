import Foundation
import NaturalLanguage

// MARK: - Language
// Script- and content-based language guessing, tuned for flashcards.
//
// Flashcard text is short, and NLLanguageRecognizer is unreliable on short
// Latin-script strings ("hire" is confidently Dutch). So script detection comes
// first — it is exact for Persian, Arabic, CJK, Cyrillic, Greek, Hebrew, Thai,
// Devanagari — and the statistical recogniser is only consulted for longer
// Latin-script text. Anything shorter falls back to the caller's default.

enum Language {

    /// Preferred voice locale per language base code.
    static let preferredLocale: [String: String] = [
        "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT",
        "pt": "pt-BR", "nl": "nl-NL", "sv": "sv-SE", "da": "da-DK", "nb": "nb-NO",
        "no": "nb-NO", "fi": "fi-FI", "pl": "pl-PL", "cs": "cs-CZ", "sk": "sk-SK",
        "hu": "hu-HU", "ro": "ro-RO", "el": "el-GR", "tr": "tr-TR", "ru": "ru-RU",
        "uk": "uk-UA", "ar": "ar-SA", "fa": "fa-IR", "he": "he-IL", "hi": "hi-IN",
        "th": "th-TH", "vi": "vi-VN", "id": "id-ID", "ms": "ms-MY", "ja": "ja-JP",
        "ko": "ko-KR", "zh": "zh-CN", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
        "ca": "ca-ES", "hr": "hr-HR", "bg": "bg-BG",
    ]

    /// Human-readable name for a locale, e.g. "en-US" → "English (US)".
    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: base(of: code))
            ?? code
    }

    static func base(of code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
    }

    static func sameBase(_ a: String, _ b: String) -> Bool {
        base(of: a).lowercased() == base(of: b).lowercased()
    }

    static func normalize(_ code: String) -> String {
        if code.contains("-"), preferredLocale.values.contains(code) { return code }
        return preferredLocale[code] ?? preferredLocale[base(of: code)] ?? code
    }

    // MARK: - Detection

    /// Best-effort language for a snippet. Returns nil when there isn't enough
    /// signal, so callers can fall back to the deck's study language.
    static func detect(_ text: String) -> String? {
        let trimmed = text.collapsedWhitespace
        guard !trimmed.isEmpty else { return nil }
        if let script = scriptLanguage(trimmed) { return script }

        // Latin script: only trust the recogniser on a reasonable amount of text.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= 4, trimmed.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(trimmed.prefix(400)))
        guard let language = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard (hypotheses[language] ?? 0) >= 0.75 else { return nil }
        return normalize(language.rawValue)
    }

    /// Exact detection for non-Latin writing systems, by character range.
    static func scriptLanguage(_ text: String) -> String? {
        var counts: [String: Int] = [:]
        var letters = 0
        for scalar in text.unicodeScalars {
            // ZWNJ is a format character, not a letter, but it is a strong hint.
            guard CharacterSet.letters.contains(scalar) || scalar.value == 0x200C else { continue }
            if scalar.value != 0x200C { letters += 1 }
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                // Arabic block — Persian is distinguished by its extra letters.
                counts["ar", default: 0] += 1
                if [0x067E, 0x0686, 0x0698, 0x06AF, 0x06CC, 0x06A9].contains(Int(scalar.value)) {
                    counts["fa", default: 0] += 3
                }
            case 0x200C: // ZWNJ — ubiquitous in Persian, rare in Arabic
                counts["fa", default: 0] += 2
            case 0x0400...0x04FF: counts["ru", default: 0] += 1
            case 0x0370...0x03FF: counts["el", default: 0] += 1
            case 0x0590...0x05FF: counts["he", default: 0] += 1
            case 0x0900...0x097F: counts["hi", default: 0] += 1
            case 0x0E00...0x0E7F: counts["th", default: 0] += 1
            case 0x3040...0x309F, 0x30A0...0x30FF: counts["ja", default: 0] += 2
            case 0xAC00...0xD7AF, 0x1100...0x11FF: counts["ko", default: 0] += 2
            case 0x4E00...0x9FFF: counts["zh", default: 0] += 1
            default: break
            }
        }
        guard letters > 0 else { return nil }
        let nonLatin = counts.values.reduce(0, +)
        guard Double(nonLatin) / Double(letters) > 0.4 else { return nil }
        // Kana anywhere means Japanese even when kanji dominate.
        if let japanese = counts["ja"], japanese > 0 { return "ja-JP" }
        if let persian = counts["fa"], persian > 0 { return "fa-IR" }
        guard let winner = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return preferredLocale[winner] ?? winner
    }

    static func isLatinScript(_ code: String) -> Bool {
        !["ar", "fa", "he", "hi", "th", "ja", "ko", "zh", "ru", "uk", "el", "bg"].contains(base(of: code))
    }

    /// Language names that appear as flashcard field names, mapped to a voice locale.
    static let fieldNameLanguages: [String: String] = [
        "persian": "fa-IR", "farsi": "fa-IR", "arabic": "ar-SA", "chinese": "zh-CN",
        "mandarin": "zh-CN", "japanese": "ja-JP", "korean": "ko-KR", "spanish": "es-ES",
        "french": "fr-FR", "german": "de-DE", "italian": "it-IT", "portuguese": "pt-BR",
        "russian": "ru-RU", "turkish": "tr-TR", "hindi": "hi-IN", "urdu": "ur-PK",
        "hebrew": "he-IL", "thai": "th-TH", "vietnamese": "vi-VN", "indonesian": "id-ID",
        "polish": "pl-PL", "dutch": "nl-NL", "swedish": "sv-SE", "greek": "el-GR",
        "ukrainian": "uk-UA", "english": "en-US",
    ]

    /// The language a field name declares, if any. A field called "Persian"
    /// answers a question the script cannot: most Persian words are written with
    /// plain Arabic letters and are indistinguishable from Arabic in isolation.
    static func fromFieldName(_ name: String) -> String? {
        let key = name.lowercased().filter { $0.isLetter || $0 == " " }.collapsedWhitespace
        if let exact = fieldNameLanguages[key] { return exact }
        let tokens = Set(key.split(separator: " ").map(String.init))
        for (language, code) in fieldNameLanguages where tokens.contains(language) { return code }
        return nil
    }

    /// Field names that name a language are translation fields ("Persian", "Farsi").
    static func isTranslationFieldName(_ key: String) -> Bool {
        if key == "english" { return false } // the study language, not a translation
        if fromFieldName(key) != nil { return true }
        return ["native", "l1", "mother tongue", "translation"].contains(key)
    }
}
