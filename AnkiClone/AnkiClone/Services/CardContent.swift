import Foundation

// MARK: - CardContent
// A note's fields, understood rather than just concatenated.
//
// The point of this type is pronunciation: a vocabulary card holds a *word*
// and, usually, one or more *example sentences*. Speaking the whole card as one
// blob reads the headword, its phonetic respelling, the part of speech, the
// definition and any native-language translation in a single breath — which is
// useless for learning. CardContent pulls those apart so each can be shown and
// spoken on its own.

struct CardContent {
    /// The word being learned, cleaned for display ("ABERRANT(ADJECTIVE)" → "Aberrant").
    var headword: String = ""
    /// The form handed to the speech synthesiser (lowercased when the source SHOUTS).
    var spokenHeadword: String = ""
    var partOfSpeech: String?
    /// Phonetic respelling / IPA. Shown, never spoken.
    var phonetic: String?
    var definitions: [String] = []
    var examples: [Example] = []
    var synonyms: [String] = []
    var antonyms: [String] = []
    var translations: [Translation] = []
    /// Anything recognised but not slotted above — shown in a "More" section.
    var extras: [Extra] = []
    /// `[sound:…]` filenames found in the note, in field order.
    var audioFilenames: [String] = []
    /// True when the note parsed into a recognisable word + meaning shape.
    var isVocabulary: Bool = false
    /// BCP-47-ish language for the headword, e.g. "en-US".
    var language: String = "en-US"

    struct Example: Identifiable, Hashable {
        let id = UUID()
        var text: String
        /// Language of this sentence, when it differs from the headword's.
        var language: String?
    }

    struct Translation: Identifiable, Hashable {
        let id = UUID()
        var label: String
        var text: String
        var language: String?
    }

    struct Extra: Identifiable, Hashable {
        let id = UUID()
        var label: String
        var text: String
    }

    var hasBackContent: Bool {
        !definitions.isEmpty || !examples.isEmpty || !translations.isEmpty
            || !synonyms.isEmpty || !antonyms.isEmpty || !extras.isEmpty
    }

    /// Everything worth speaking on the answer side, in reading order.
    var answerSpeech: [SpeechService.Item] {
        var items: [SpeechService.Item] = []
        if let first = definitions.first {
            items.append(.init(text: first, language: language))
        }
        for example in examples {
            items.append(.init(text: example.text, language: example.language ?? language))
        }
        return items
    }
}

// MARK: - Analyzer

enum CardContentAnalyzer {

    /// Characters decks use as an example-sentence bullet. `\u{F0B7}` is the
    /// Symbol-font bullet that Word/Wingdings exports leave behind — the TOEFL
    /// sample deck separates its examples with it.
    static let bulletCharacters = CharacterSet(charactersIn: "\u{F0B7}\u{2022}\u{00B7}\u{2023}\u{25AA}\u{25CF}\u{2219}\u{FFFD}")

    static func analyze(note: Note, noteType: NoteType?) -> CardContent {
        let names = noteType?.fieldNames ?? (0..<note.fieldValues.count).map { "Field \($0 + 1)" }
        var content = CardContent()

        // Collect [sound:…] references before any HTML is stripped.
        for value in note.fieldValues {
            content.audioFilenames.append(contentsOf: soundFilenames(in: value))
        }

        // Pass 1 — classify every non-empty field by its name.
        var buckets: [FieldRole: [(label: String, html: String)]] = [:]
        for (index, name) in names.enumerated() {
            guard index < note.fieldValues.count else { continue }
            let html = note.fieldValues[index]
            let plain = HTMLText.plainText(stripSoundTags(html))
            guard !plain.isBlank else { continue }
            let role = FieldRole.classify(fieldName: name, value: plain, isFirstField: index == 0)
            buckets[role, default: []].append((name, html))
        }

        // Headword
        if let raw = buckets[.headword]?.first {
            let plain = HTMLText.plainText(stripSoundTags(raw.html))
            let parsed = splitHeadword(plain)
            content.headword = parsed.word
            content.partOfSpeech = parsed.partOfSpeech
        }
        if content.headword.isBlank, let fallback = note.fieldValues.first {
            content.headword = HTMLText.plainText(stripSoundTags(fallback))
        }
        content.language = Language.detect(content.headword) ?? "en-US"
        content.spokenHeadword = speakableHeadword(content.headword)
        content.headword = displayHeadword(content.headword)

        // Simple single-value roles
        if let pos = buckets[.partOfSpeech]?.first {
            let value = HTMLText.plainText(pos.html)
            if !value.isBlank { content.partOfSpeech = normalizePartOfSpeech(value) }
        }
        if let phonetic = buckets[.phonetic]?.first {
            content.phonetic = HTMLText.plainText(phonetic.html)
        }
        for entry in buckets[.synonyms] ?? [] {
            content.synonyms.append(contentsOf: splitList(HTMLText.plainText(entry.html)))
        }
        for entry in buckets[.antonyms] ?? [] {
            content.antonyms.append(contentsOf: splitList(HTMLText.plainText(entry.html)))
        }
        for entry in buckets[.translation] ?? [] {
            let text = HTMLText.plainText(entry.html)
            guard !text.isBlank else { continue }
            // A field named "Persian" settles a question the script cannot:
            // most Persian words are spelled with plain Arabic letters.
            let language = Language.fromFieldName(entry.label) ?? Language.detect(text)
            content.translations.append(.init(label: entry.label, text: text, language: language))
        }

        // Dedicated example fields
        for entry in buckets[.examples] ?? [] {
            for sentence in splitSentenceBlocks(entry.html) {
                content.examples.append(makeExample(sentence, primary: content.language))
            }
        }

        // Definition fields — these often carry the examples too, glued on with a bullet.
        for entry in buckets[.definition] ?? [] {
            let parsed = parseDefinitionField(entry.html, headword: content.headword)
            content.definitions.append(contentsOf: parsed.definitions)
            for sentence in parsed.examples {
                content.examples.append(makeExample(sentence, primary: content.language))
            }
            content.synonyms.append(contentsOf: parsed.synonyms)
            content.antonyms.append(contentsOf: parsed.antonyms)
            for translation in parsed.translations {
                content.translations.append(.init(label: "Translation", text: translation, language: Language.detect(translation)))
            }
        }

        for entry in buckets[.other] ?? [] {
            let text = HTMLText.plainText(entry.html)
            if !text.isBlank { content.extras.append(.init(label: entry.label, text: text)) }
        }

        content.definitions = tidy(content.definitions)
        content.synonyms = tidy(content.synonyms)
        content.antonyms = tidy(content.antonyms)
        content.examples = dedupeExamples(content.examples)
        content.isVocabulary = !content.headword.isBlank
            && content.headword.split(separator: " ").count <= 5
            && content.hasBackContent
        return content
    }

    // MARK: - Field roles

    enum FieldRole: Hashable {
        case headword, phonetic, partOfSpeech, definition, examples
        case synonyms, antonyms, translation, other, ignored

        static func classify(fieldName: String, value: String, isFirstField: Bool) -> FieldRole {
            let key = fieldName.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)

            func matches(_ needles: [String]) -> Bool {
                needles.contains { key == $0 || key.hasPrefix($0 + " ") || key.hasSuffix(" " + $0) || key.contains($0) }
            }

            if matches(["pic", "picture", "image", "img", "photo", "diagram", "media", "audio", "sound", "url", "link", "source", "notice", "add reverse", "id"]) {
                return .ignored
            }
            // Phonetics must be tested before "part of speech"/"person" style names,
            // and before translations ("Phone. Persian" is a phonetic field).
            if matches(["phonetic", "phonetics", "pronunciation", "ipa", "phone", "phon", "transcription", "reading", "kana", "furigana", "romaji", "pinyin"]) {
                return .phonetic
            }
            if matches(["part of speech", "partofspeech", "pos", "word type", "wordtype", "register", "grammar"]) {
                return .partOfSpeech
            }
            if matches(["example", "examples", "sentence", "sentences", "usage", "context", "sample", "in context", "collocation", "collocations"]) {
                return .examples
            }
            if matches(["synonym", "synonyms", "syn", "similar"]) { return .synonyms }
            if matches(["antonym", "antonyms", "ant", "opposite"]) { return .antonyms }
            if Language.isTranslationFieldName(key) { return .translation }
            if matches(["definition", "meaning", "gloss", "sense", "english", "def"]) { return .definition }
            if matches(["word", "front", "expression", "term", "vocabulary", "vocab", "headword", "question", "kanji", "target", "spelling"]) {
                return .headword
            }
            if matches(["back", "answer", "translation", "notes", "note", "explanation", "extra", "comment"]) {
                return .definition
            }
            // Anki's per-part-of-speech sub-entry fields: "v.", "n.", "adj2.", …
            if key.range(of: #"^(v|n|adj|adv|conj|prep|pron|interj)\d?$"#, options: .regularExpression) != nil {
                return .definition
            }
            if isFirstField { return .headword }
            // Unnamed field: decide from the content's script.
            if let language = Language.detect(value), !Language.isLatinScript(language) {
                return .translation
            }
            return .other
        }
    }

    // MARK: - Headword

    /// "ABERRANT(ADJECTIVE)" → ("ABERRANT", "adjective"); "run (verb)" → ("run", "verb").
    static func splitHeadword(_ raw: String) -> (word: String, partOfSpeech: String?) {
        let trimmed = raw.collapsedWhitespace
        guard let open = trimmed.range(of: #"\s*[\(\[]"#, options: [.regularExpression, .backwards]),
              let close = trimmed.range(of: #"[\)\]]\s*$"#, options: .regularExpression),
              open.lowerBound < close.lowerBound
        else {
            return (trimmed, nil)
        }
        let inside = String(trimmed[open.upperBound..<close.lowerBound]).collapsedWhitespace
        let word = String(trimmed[trimmed.startIndex..<open.lowerBound]).collapsedWhitespace
        // Only a recognised part of speech may be peeled off — "bank (of a river)"
        // keeps its parenthetical because that is part of the headword.
        guard !word.isBlank, let pos = knownPartOfSpeech(inside) else { return (trimmed, nil) }
        return (word, pos)
    }

    /// Strict: returns a value only for text that really names a part of speech.
    static func knownPartOfSpeech(_ raw: String) -> String? {
        let key = raw.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let known: [String: String] = [
            "noun": "noun", "n": "noun", "verb": "verb", "v": "verb",
            "adjective": "adjective", "adj": "adjective", "a": "adjective",
            "adverb": "adverb", "adv": "adverb",
            "preposition": "preposition", "prep": "preposition",
            "pronoun": "pronoun", "pron": "pronoun",
            "conjunction": "conjunction", "conj": "conjunction",
            "interjection": "interjection", "interj": "interjection",
            "phrase": "phrase", "idiom": "idiom", "phrasal verb": "phrasal verb",
        ]
        if let hit = known[key] { return hit }
        // Multi-word values like "verb, transitive" keep their first token.
        if let first = key.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " }).first,
           let hit = known[String(first)] {
            return hit
        }
        return nil
    }

    /// Lenient: for a field explicitly named "Part of Speech", whatever it holds
    /// is the part of speech, even if it isn't one we have a name for.
    static func normalizePartOfSpeech(_ raw: String) -> String? {
        if let known = knownPartOfSpeech(raw) { return known }
        let value = raw.collapsedWhitespace
        return value.count <= 24 && !value.isEmpty ? value.lowercased() : nil
    }

    /// All-caps headwords make some voices spell the word out letter by letter.
    static func speakableHeadword(_ word: String) -> String {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1, letters.allSatisfy({ $0.isUppercase }) else { return word }
        return word.lowercased()
    }

    /// SHOUTED source words read better sentence-cased on screen.
    static func displayHeadword(_ word: String) -> String {
        let letters = word.filter(\.isLetter)
        guard letters.count > 3, letters.allSatisfy({ $0.isUppercase }) else { return word }
        return word.split(separator: " ")
            .map { $0.prefix(1) + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    // MARK: - Definition fields

    struct ParsedDefinition {
        var definitions: [String] = []
        var examples: [String] = []
        var synonyms: [String] = []
        var antonyms: [String] = []
        var translations: [String] = []
    }

    /// Split a "Back"/"Definition" field into its parts.
    ///
    /// Two shapes show up in real decks and both are handled here:
    ///  * flat text where a bullet separates gloss from examples —
    ///    `"Speed up: hasten ≠ decelerate • The car accelerated away."`
    ///  * marked-up HTML where examples are italic or list items.
    static func parseDefinitionField(_ html: String, headword: String) -> ParsedDefinition {
        var parsed = ParsedDefinition()
        let blocks = HTMLText.blocks(stripSoundTags(html))
        var sawDefinition = false

        for block in blocks {
            // A block may itself contain bulleted examples.
            let pieces = splitOnBullets(block.text)
            for (offset, piece) in pieces.enumerated() {
                let text = piece.collapsedWhitespace
                guard !text.isBlank, !isNoise(text) else { continue }

                if let language = Language.detect(text), !Language.isLatinScript(language) {
                    parsed.translations.append(text)
                    continue
                }
                // Anything after a bullet is an example by construction.
                let bulleted = offset > 0
                if bulleted || looksLikeExample(text, block: block, headword: headword, alreadyHaveDefinition: sawDefinition) {
                    parsed.examples.append(stripLeadingBullet(text))
                    continue
                }

                let split = splitAntonyms(text)
                if !split.antonyms.isEmpty { parsed.antonyms.append(contentsOf: split.antonyms) }
                let glosses = splitGlossList(split.rest)
                if glosses.count > 1 {
                    parsed.definitions.append(contentsOf: glosses)
                } else if !split.rest.isBlank {
                    parsed.definitions.append(split.rest)
                }
                sawDefinition = true
            }
        }
        return parsed
    }

    /// Decide whether a block of back-side text is an example sentence.
    static func looksLikeExample(_ text: String, block: HTMLBlock, headword: String, alreadyHaveDefinition: Bool) -> Bool {
        if block.classes.contains(where: { $0.contains("def") || $0.contains("sense") || $0.contains("meaning") }) {
            return false
        }
        let words = text.split(whereSeparator: { $0 == " " }).count
        if block.isListItem && words >= 3 { return true }
        if block.isItalic && words >= 3 { return true }
        if startsWithBullet(text) { return true }
        // Unmarked text is only an example once the meaning has been stated —
        // the first, unmarked chunk of a definition field *is* the definition,
        // even when it repeats the headword ("account for: to explain …").
        guard alreadyHaveDefinition else { return false }
        if containsHeadword(text, headword: headword) && words >= 4 { return true }
        if words >= 6 && endsLikeSentence(text) { return true }
        return false
    }

    // MARK: - Text utilities

    static func splitOnBullets(_ text: String) -> [String] {
        text.components(separatedBy: bulletCharacters)
            .map { $0.collapsedWhitespace }
            .filter { !$0.isEmpty }
    }

    static func startsWithBullet(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        if bulletCharacters.contains(first) { return true }
        return text.hasPrefix("- ") || text.hasPrefix("– ") || text.hasPrefix("— ") || text.hasPrefix("* ")
    }

    static func stripLeadingBullet(_ text: String) -> String {
        var t = text
        while let first = t.unicodeScalars.first, bulletCharacters.contains(first) { t.removeFirst() }
        for prefix in ["- ", "– ", "— ", "* "] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        return t.collapsedWhitespace
    }

    static func endsLikeSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?。！？".contains(last)
    }

    /// Word-boundary match that tolerates inflection: "accelerate" matches
    /// "accelerated", "accelerating"; "myriad" matches "myriads".
    static func containsHeadword(_ text: String, headword: String) -> Bool {
        let stem = headword.lowercased().filter { $0.isLetter || $0 == " " }
        guard stem.count >= 3 else { return false }
        let root = String(stem.prefix(max(4, stem.count - 3)))
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if token.hasPrefix(root) { return true }
        }
        return false
    }

    /// "Speed up: expedite: hasten" → three glosses. Only splits when every part
    /// is short enough to be a gloss rather than a sentence.
    static func splitGlossList(_ text: String) -> [String] {
        guard !endsLikeSentence(text) else { return [text] }
        let separators: [Character] = [":", ";"]
        guard text.contains(where: { separators.contains($0) }) else { return [text] }
        let parts = text.split(whereSeparator: { separators.contains($0) })
            .map { $0.collapsedWhitespace }
            .filter { !$0.isEmpty }
        guard parts.count > 1, parts.allSatisfy({ $0.split(separator: " ").count <= 6 }) else { return [text] }
        return parts
    }

    /// "hasten ≠ decelerate" → (rest: "hasten", antonyms: ["decelerate"]).
    static func splitAntonyms(_ text: String) -> (rest: String, antonyms: [String]) {
        let markers = ["≠", "opp.", "opposite:", "ant."]
        for marker in markers {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let rest = String(text[text.startIndex..<range.lowerBound]).collapsedWhitespace
            let tail = String(text[range.upperBound...]).collapsedWhitespace
            return (rest, splitList(tail))
        }
        return (text, [])
    }

    static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { ",;:/،".contains($0) })
            .map { $0.collapsedWhitespace }
            .filter { !$0.isEmpty && $0.count < 60 }
    }

    /// Sentence-per-line splitting for dedicated example fields.
    static func splitSentenceBlocks(_ html: String) -> [String] {
        HTMLText.blocks(stripSoundTags(html))
            .flatMap { splitOnBullets($0.text) }
            .map(stripLeadingBullet)
            .filter { !$0.isBlank && !isNoise($0) }
    }

    /// Dictionary cruft that should never be shown or spoken on its own.
    static func isNoise(_ text: String) -> Bool {
        let t = text.collapsedWhitespace
        if t.count <= 1 { return true }
        // Grammar codes such as "[ + that ]" or "(C)".
        if t.hasPrefix("["), t.hasSuffix("]"), t.count <= 24 { return true }
        if t.hasPrefix("("), t.hasSuffix(")"), t.count <= 12 { return true }
        if t.allSatisfy({ !$0.isLetter }) { return true }
        return false
    }

    static func makeExample(_ text: String, primary: String) -> CardContent.Example {
        let detected = Language.detect(text)
        let language = (detected != nil && detected != primary && !Language.sameBase(detected!, primary)) ? detected : nil
        return .init(text: text, language: language)
    }

    static func tidy(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values.map({ $0.collapsedWhitespace }) where !value.isBlank && !isNoise(value) {
            let key = value.lowercased()
            if seen.insert(key).inserted { out.append(value) }
        }
        return out
    }

    static func dedupeExamples(_ examples: [CardContent.Example]) -> [CardContent.Example] {
        var seen = Set<String>()
        var out: [CardContent.Example] = []
        for example in examples {
            let key = example.text.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(example)
        }
        return out
    }

    // MARK: - Sound tags

    static func soundFilenames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[sound:(.*?)\]"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let name = ns.substring(with: match.range(at: 1)).collapsedWhitespace
            return name.isEmpty ? nil : name
        }
    }

    static func stripSoundTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[sound:.*?\]"#, with: " ", options: .regularExpression)
    }
}
