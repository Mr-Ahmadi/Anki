import XCTest
@testable import AnkiClone

// MARK: - Template rendering

final class TemplateRendererTests: XCTestCase {

    private func basicNoteType() -> NoteType {
        NoteType(
            ankiId: 1,
            name: "Basic",
            css: ".card { font-size: 20px; }",
            fieldNames: ["Front", "Back"],
            templates: [CardTemplateData(ord: 0, name: "Card 1", qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}")]
        )
    }

    func testFieldSubstitution() {
        let noteType = basicNoteType()
        let note = Note(ankiId: 1, guid: "g", modelId: 1, mod: 0, tags: "", fieldValues: ["Hello", "World"], sortField: "Hello", checksum: 0)
        let fields = TemplateRenderer.fieldsDictionary(note: note, noteType: noteType)

        let question = TemplateRenderer.render(template: "{{Front}}", fields: fields, noteType: noteType)
        XCTAssertTrue(question.contains("Hello"))

        let answer = TemplateRenderer.render(template: "{{FrontSide}}<hr>{{Back}}", fields: fields, noteType: noteType, frontSide: question)
        XCTAssertTrue(answer.contains("World"))
        XCTAssertTrue(answer.contains("Hello"), "FrontSide should be inlined on the answer")
    }

    func testConditionalsHideEmptyFields() {
        let fields = ["Word": "run", "Notes": ""]
        let rendered = TemplateRenderer.render(
            template: "{{Word}}{{#Notes}}<div>{{Notes}}</div>{{/Notes}}",
            fields: fields,
            noteType: nil
        )
        XCTAssertTrue(rendered.contains("run"))
        XCTAssertFalse(rendered.contains("<div>"), "empty field's block should be removed")
    }

    func testClozeHidesAnswerOnQuestion() {
        let fields = ["Text": "The {{c1::capital}} of France"]
        let question = TemplateRenderer.render(template: "{{Text}}", fields: fields, noteType: nil)
        XCTAssertTrue(question.contains("[...]"))
        XCTAssertFalse(question.contains("capital"))

        let answer = TemplateRenderer.render(template: "{{Text}}", fields: fields, noteType: nil, frontSide: "q")
        XCTAssertTrue(answer.contains("capital"))
    }

    /// The "1212 Words" sample deck autoplays five remote audio elements per card.
    func testRemoteAutoplayAudioIsDefused() {
        let template = """
        {{Front}}<audio autoplay="autoplay"><source src="http://www.ldoceonline.com/media/x.mp3" type="audio/mpeg"/></audio>
        """
        let rendered = TemplateRenderer.render(template: template, fields: ["Front": "myriad"], noteType: nil)
        XCTAssertFalse(rendered.lowercased().contains("autoplay"))
        XCTAssertTrue(rendered.contains("controls"))
        XCTAssertFalse(rendered.contains("http://"), "insecure media URLs are upgraded so they can load at all")
    }

    func testSoundTagBecomesPlayer() {
        let rendered = TemplateRenderer.render(template: "{{Word}}[sound:aberrant.mp3]", fields: ["Word": "aberrant"], noteType: nil)
        XCTAssertTrue(rendered.contains("<audio"))
        XCTAssertTrue(rendered.contains("aberrant.mp3"))
    }
}

// MARK: - HTML scanning

final class HTMLTextTests: XCTestCase {

    func testEntitiesAreDecoded() {
        XCTAssertEqual(HTMLText.plainText("a&nbsp;&amp;&nbsp;b"), "a & b")
        XCTAssertEqual(HTMLText.plainText("caf&#233; &#x41;"), "café A")
    }

    func testScriptAndStyleContentIsDropped() {
        let html = "<style>.card{color:red}</style><div>Real text</div><script>var x=1;</script>"
        XCTAssertEqual(HTMLText.plainText(html), "Real text")
    }

    /// A sentence broken up by inline links must survive as one block, otherwise
    /// examples get split into unreadable fragments.
    func testInlineMarkupDoesNotFragmentASentence() {
        let html = #"<div><span style="font-style: italic;">And now myriads&nbsp;<span style="font-weight: 700;">of</span>&nbsp;<a href="https://x">bars</a>&nbsp;are opening.</span></div>"#
        let blocks = HTMLText.blocks(html)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "And now myriads of bars are opening.")
        XCTAssertTrue(blocks[0].isItalic, "mostly-italic text should read as italic")
    }

    func testBlockBoundariesAndListItems() {
        let html = "<div>Definition here</div><ul><li>First example.</li><li>Second example.</li></ul>"
        let blocks = HTMLText.blocks(html)
        XCTAssertEqual(blocks.map(\.text), ["Definition here", "First example.", "Second example."])
        XCTAssertFalse(blocks[0].isListItem)
        XCTAssertTrue(blocks[1].isListItem)
        XCTAssertTrue(blocks[2].isListItem)
    }

    func testClassesSurviveFromAncestors() {
        let blocks = HTMLText.blocks(#"<div class="gt-def-row">countless</div>"#)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].classes.contains("gt-def-row"))
    }
}

// MARK: - Card content analysis

final class CardContentTests: XCTestCase {

    private func note(_ values: [String], modelId: Int64 = 1) -> Note {
        Note(ankiId: Int64.random(in: 1...100_000), guid: "g", modelId: modelId, mod: 0, tags: "",
             fieldValues: values, sortField: values.first ?? "", checksum: 0)
    }

    /// Field list taken verbatim from samples/540_MUST_KNOW_WORDS_FOR_TOEFL_IBT.apkg.
    private func toeflNoteType() -> NoteType {
        NoteType(
            ankiId: 1, name: "TOEFL Vocabulary", css: "",
            fieldNames: ["Word", "Part of Speech", "Phonetic Spelling", "Definition", "Persian",
                         "Synonyms", "Phone. Syn.", "Pic", "Examples"],
            templates: [CardTemplateData(ord: 0, name: "Word to Definition",
                                         qfmt: "{{Word}}[sound:{{Word}}.mp3]{{Phonetic Spelling}}",
                                         afmt: "{{FrontSide}}<hr id=answer>{{Definition}}{{Persian}}")]
        )
    }

    /// Real note from the TOEFL sample: definition and examples share one field,
    /// separated by the Symbol-font bullet U+F0B7.
    func testTOEFLNoteSplitsDefinitionFromExamples() {
        let noteType = toeflNoteType()
        let note = note([
            "ACCELERATE(VERB)", "", "",
            "Speed up: expedite: hasten: quicken \u{F0B7} measures to accelerate the rate of economic growth \u{F0B7} The car accelerated smoothly away.",
            "", "", "", "", "",
        ])
        let content = CardContentAnalyzer.analyze(note: note, noteType: noteType)

        XCTAssertEqual(content.headword, "Accelerate")
        XCTAssertEqual(content.spokenHeadword, "accelerate", "SHOUTED words get spelled out by some voices")
        XCTAssertEqual(content.partOfSpeech, "verb")
        XCTAssertEqual(content.definitions, ["Speed up", "expedite", "hasten", "quicken"])
        XCTAssertEqual(content.examples.map(\.text), [
            "measures to accelerate the rate of economic growth",
            "The car accelerated smoothly away.",
        ])
        XCTAssertTrue(content.isVocabulary)
    }

    func testAntonymMarkerIsSeparated() {
        let noteType = toeflNoteType()
        let note = note(["DECELERATE(VERB)", "", "", "Slow down: brake ≠ accelerate", "", "", "", "", ""])
        let content = CardContentAnalyzer.analyze(note: note, noteType: noteType)
        XCTAssertEqual(content.antonyms, ["accelerate"])
        XCTAssertFalse(content.definitions.contains { $0.contains("≠") })
    }

    func testTranslationFieldGetsItsOwnLanguage() {
        let noteType = toeflNoteType()
        let note = note(["ABERRANT(ADJECTIVE)", "", "/əˈberənt/", "Unusual: atypical", "نابهنجار", "", "", "", ""])
        let content = CardContentAnalyzer.analyze(note: note, noteType: noteType)

        XCTAssertEqual(content.phonetic, "/əˈberənt/")
        XCTAssertEqual(content.translations.count, 1)
        XCTAssertEqual(content.translations.first?.text, "نابهنجار")
        XCTAssertEqual(content.translations.first?.language, "fa-IR")
        XCTAssertEqual(content.language, "en-US", "the headword stays English")
    }

    func testSoundFilenamesAreCollected() {
        let noteType = toeflNoteType()
        let note = note(["ABERRANT(ADJECTIVE)[sound:aberrant.mp3]", "", "", "Unusual", "", "", "", "", ""])
        let content = CardContentAnalyzer.analyze(note: note, noteType: noteType)
        XCTAssertEqual(content.audioFilenames, ["aberrant.mp3"])
        XCTAssertFalse(content.headword.contains("sound:"))
    }

    /// Real note from samples/1212 Words.apkg — a Basic Front/Back note whose
    /// back mixes a gloss, an italic example and an ordered list of examples.
    func testBasicNoteSplitsExamplesOutOfMarkup() {
        let noteType = NoteType(
            ankiId: 2, name: "Basic-b160f", css: "", fieldNames: ["Front", "Back"],
            templates: [CardTemplateData(ord: 0, name: "Card 1", qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr>{{Back}}")]
        )
        let back = #"""
        <div class="gt-def-row">countless, innumerable, numerous<br></div><div><span style="font-style: italic;">And now myriads&nbsp;of&nbsp;<a href="https://x">bars</a>&nbsp;are opening up along the coast.</span></div><div><ol><li>The city offers a myriad of attractions for tourists.</li><li>The scientist studied the myriad forms of life in the ocean.</li></ol></div>
        """#
        let content = CardContentAnalyzer.analyze(note: note(["myriad", back], modelId: 2), noteType: noteType)

        XCTAssertEqual(content.headword, "myriad")
        XCTAssertEqual(content.definitions.first, "countless, innumerable, numerous")
        XCTAssertEqual(content.examples.count, 3)
        XCTAssertTrue(content.examples[0].text.hasPrefix("And now myriads"))
        XCTAssertTrue(content.examples[1].text.contains("attractions"))
        XCTAssertTrue(content.isVocabulary)
    }

    /// The "dispensable" note uses "•"-prefixed grey spans for its examples.
    func testBulletPrefixedExamplesAreDetected() {
        let noteType = NoteType(
            ankiId: 2, name: "Basic", css: "", fieldNames: ["Front", "Back"],
            templates: [CardTemplateData(ord: 0, name: "Card 1", qfmt: "{{Front}}", afmt: "{{Back}}")]
        )
        let back = #"""
        <div class="gt-def-row">able to be replaced or done without; superfluous.</div>not necessary<br><span style="color: gray;">•&nbsp;But neither do such concepts reduce to the corresponding predicates.<br></span>
        """#
        let content = CardContentAnalyzer.analyze(note: note(["dispensable", back], modelId: 2), noteType: noteType)
        XCTAssertEqual(content.examples.count, 1)
        XCTAssertTrue(content.examples[0].text.hasPrefix("But neither"))
        XCTAssertFalse(content.examples[0].text.contains("•"))
        XCTAssertTrue(content.definitions.contains("not necessary"))
    }

    func testShortBackIsAllDefinition() {
        let noteType = NoteType(
            ankiId: 2, name: "Basic", css: "", fieldNames: ["Front", "Back"],
            templates: [CardTemplateData(ord: 0, name: "Card 1", qfmt: "{{Front}}", afmt: "{{Back}}")]
        )
        let content = CardContentAnalyzer.analyze(note: note(["hire", "employ"], modelId: 2), noteType: noteType)
        XCTAssertEqual(content.definitions, ["employ"])
        XCTAssertTrue(content.examples.isEmpty)
    }

    func testDedicatedExampleFieldIsUsed() {
        let noteType = NoteType(
            ankiId: 3, name: "Vocab", css: "", fieldNames: ["Word", "Meaning", "Examples"],
            templates: [CardTemplateData(ord: 0, name: "C", qfmt: "{{Word}}", afmt: "{{Meaning}}")]
        )
        let content = CardContentAnalyzer.analyze(
            note: note(["ubiquitous", "found everywhere", "<div>Screens are ubiquitous.</div><div>Plastic is ubiquitous in the ocean.</div>"], modelId: 3),
            noteType: noteType
        )
        XCTAssertEqual(content.definitions, ["found everywhere"])
        XCTAssertEqual(content.examples.map(\.text), ["Screens are ubiquitous.", "Plastic is ubiquitous in the ocean."])
    }

    func testAnswerSpeechKeepsWordOutOfTheSentenceRun() {
        let noteType = NoteType(
            ankiId: 3, name: "Vocab", css: "", fieldNames: ["Word", "Meaning", "Examples"],
            templates: [CardTemplateData(ord: 0, name: "C", qfmt: "{{Word}}", afmt: "{{Meaning}}")]
        )
        let content = CardContentAnalyzer.analyze(
            note: note(["ubiquitous", "found everywhere", "Screens are ubiquitous."], modelId: 3),
            noteType: noteType
        )
        let speech = content.answerSpeech
        XCTAssertEqual(speech.count, 2)
        XCTAssertFalse(speech.contains { $0.text.contains("ubiquitous.") && $0.text.contains("found everywhere") })
    }

    func testHeadwordSplitting() {
        XCTAssertEqual(CardContentAnalyzer.splitHeadword("ACCOUNT FOR(VERB)").word, "ACCOUNT FOR")
        XCTAssertEqual(CardContentAnalyzer.splitHeadword("ACCOUNT FOR(VERB)").partOfSpeech, "verb")
        XCTAssertEqual(CardContentAnalyzer.splitHeadword("run").word, "run")
        XCTAssertNil(CardContentAnalyzer.splitHeadword("run").partOfSpeech)
        // A parenthetical that isn't a part of speech is left attached.
        XCTAssertEqual(CardContentAnalyzer.splitHeadword("bank (of a river)").word, "bank (of a river)")
    }
}

// MARK: - Speech text safety

/// Nothing that isn't a word may reach the synthesiser. Every case here is one
/// that a real shared deck produces.
final class SpeakableTextTests: XCTestCase {

    private func spoken(_ raw: String) -> String { SpeechService.speakableText(raw) }

    func testPlainMarkupIsRemoved() {
        XCTAssertEqual(spoken("<div><b>hello</b> <i>world</i></div>"), "hello world")
        XCTAssertEqual(spoken(#"<span style="color: red">red</span>"#), "red")
    }

    /// Scraper-exported fields are routinely double-encoded, so the markup only
    /// appears after the entities are decoded.
    func testEntityEncodedMarkupIsRemoved() {
        XCTAssertEqual(spoken("&lt;div&gt;hello&lt;/div&gt;"), "hello")
        XCTAssertEqual(spoken("&amp;lt;b&amp;gt;bold&amp;lt;/b&amp;gt;"), "bold")
    }

    func testAttributesContainingAngleBracketsDoNotLeak() {
        let html = #"<a href="https://x.com/a>b" title="1 > 2">link text</a>"#
        let result = spoken(html)
        XCTAssertEqual(result, "link text")
        XCTAssertFalse(result.contains("href"))
    }

    func testUnterminatedTagDoesNotLeak() {
        XCTAssertFalse(spoken("word <div class=").contains("<"))
        XCTAssertFalse(spoken("word <div class=").contains("div"))
    }

    func testScriptAndStyleBodiesAreNeverSpoken() {
        let html = "<style>.card{color:red}</style>word<script>alert('hi')</script>"
        let result = spoken(html)
        XCTAssertEqual(result, "word")
        XCTAssertFalse(result.contains("alert"))
    }

    /// Real inequalities in a card must survive — only markup is markup.
    func testLoneAngleBracketsAreKept() {
        XCTAssertTrue(spoken("5 < 6 and 7 > 4").contains("5 < 6"))
    }

    func testSoundTagsAndClozeScaffoldingAreRemoved() {
        XCTAssertEqual(spoken("aberrant[sound:aberrant.mp3]"), "aberrant")
        XCTAssertEqual(spoken("The [...] of France"), "The of France")
        XCTAssertFalse(spoken("<a class=\"hint\">[hint]</a>answer").contains("hint"))
    }

    func testUrlsAreNotRead() {
        XCTAssertFalse(spoken("see https://www.ldoceonline.com/dictionary/x now").contains("ldoceonline"))
        XCTAssertFalse(spoken("visit www.example.com today").contains("example"))
    }

    /// The TOEFL deck separates examples with U+F0B7, a Symbol-font bullet that
    /// lands in the private use area; voices should pause, not vocalise it.
    func testPrivateUseAndInvisibleCharactersBecomePauses() {
        let result = spoken("Speed up \u{F0B7} The car accelerated.")
        XCTAssertEqual(result, "Speed up The car accelerated.")
        XCTAssertFalse(result.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        XCTAssertFalse(spoken("zero\u{200B}width").contains("\u{200B}"))
    }

    func testEntitiesBecomeTheCharactersTheyName() {
        XCTAssertEqual(spoken("caf&eacute;".replacingOccurrences(of: "&eacute;", with: "&#233;")), "café")
        XCTAssertEqual(spoken("a&nbsp;&amp;&nbsp;b"), "a & b")
    }

    func testLengthIsCapped() {
        let long = String(repeating: "word ", count: 1000)
        XCTAssertLessThanOrEqual(spoken(long).count, 1200)
    }

    /// The end-to-end path a card actually takes: rendered template → speech.
    func testRenderedCardTemplateProducesCleanSpeech() {
        let fields = ["Front": "myriad", "Back": #"<div class="gt-def-row">countless<br></div><div><i>a myriad of <a href="https://x">choices</a></i></div>"#]
        let question = TemplateRenderer.render(template: "{{Front}}", fields: fields, noteType: nil)
        let answer = TemplateRenderer.render(template: "{{FrontSide}}<hr id=answer>{{Back}}", fields: fields, noteType: nil, frontSide: question)
        let result = spoken(answer)
        XCTAssertEqual(result, "myriad countless a myriad of choices")
    }
}

// MARK: - Language detection

final class LanguageTests: XCTestCase {

    /// Persian-specific letters and the zero-width non-joiner settle the script;
    /// a Persian word spelled with only shared Arabic letters cannot, and the
    /// field name has to resolve it instead (see `fromFieldName`).
    func testPersianIsDistinguishedFromArabicWhenItCanBe() {
        XCTAssertEqual(Language.detect("پژوهش گران"), "fa-IR")
        XCTAssertEqual(Language.detect("می\u{200C}شود"), "fa-IR")
        XCTAssertEqual(Language.detect("مرحبا كيف حالك"), "ar-SA")
        XCTAssertEqual(Language.detect("نابهنجار"), "ar-SA", "shared letters only — genuinely ambiguous")
    }

    func testFieldNamesDeclareTheirLanguage() {
        XCTAssertEqual(Language.fromFieldName("Persian"), "fa-IR")
        XCTAssertEqual(Language.fromFieldName("Persian v."), "fa-IR")
        XCTAssertEqual(Language.fromFieldName("Meaning (Japanese)"), "ja-JP")
        XCTAssertNil(Language.fromFieldName("Definition"))
    }

    func testScriptsAreRecognised() {
        XCTAssertEqual(Language.detect("こんにちは"), "ja-JP")
        XCTAssertEqual(Language.detect("안녕하세요"), "ko-KR")
        XCTAssertEqual(Language.detect("Привет как дела"), "ru-RU")
    }

    /// Short Latin words carry no reliable signal — better to fall back to the
    /// user's study language than to guess Dutch for "hire".
    func testShortLatinTextIsNotGuessed() {
        XCTAssertNil(Language.detect("hire"))
        XCTAssertNil(Language.detect("a myriad of"))
    }

    func testTranslationFieldNames() {
        XCTAssertTrue(Language.isTranslationFieldName("persian"))
        XCTAssertTrue(Language.isTranslationFieldName("persian v"))
        XCTAssertFalse(Language.isTranslationFieldName("definition"))
    }
}

// MARK: - Scheduling

final class SchedulerTests: XCTestCase {

    private func card(type: Int, queue: Int, interval: Int = 0, ease: Int = 2500) -> Card {
        Card(ankiId: 1, ord: 0, mod: 0, type: type, queue: queue, due: 0, dueDate: Date(),
             interval: interval, easeFactor: ease, reps: 0, lapses: 0, left: 0, odue: 0,
             flags: 0, data: "", deckId: 1, noteId: 1)
    }

    func testNewCardGoodGraduates() {
        let result = Scheduler().answer(card: card(type: 0, queue: 0), rating: .good)
        XCTAssertEqual(result.newInterval, 1)
        XCTAssertEqual(result.newType, 2)
    }

    func testAgainOnReviewCardLapsesIntoRelearning() {
        let result = Scheduler().answer(card: card(type: 2, queue: 2, interval: 30), rating: .again)
        XCTAssertEqual(result.newType, 3)
        XCTAssertEqual(result.newLapses, 1)
        XCTAssertLessThan(result.newEaseFactor, 2500)
    }

    func testGoodOnReviewGrowsByEase() {
        let result = Scheduler().answer(card: card(type: 2, queue: 2, interval: 10, ease: 2500), rating: .good)
        XCTAssertEqual(result.newInterval, 25)
    }

    func testEasyBeatsGoodBeatsHard() {
        let scheduler = Scheduler()
        let subject = card(type: 2, queue: 2, interval: 10)
        let hard = scheduler.answer(card: subject, rating: .hard).newInterval
        let good = scheduler.answer(card: subject, rating: .good).newInterval
        let easy = scheduler.answer(card: subject, rating: .easy).newInterval
        XCTAssertLessThan(hard, good)
        XCTAssertLessThan(good, easy)
    }

    func testIntervalPreviewsAreOfferedForEveryRating() {
        let previews = Scheduler().nextIntervals(for: card(type: 0, queue: 0))
        XCTAssertEqual(previews.count, 4)
        XCTAssertFalse(previews.values.contains { $0.isEmpty })
    }
}

// MARK: - Import

final class ImportTests: XCTestCase {

    func testReviewDueDateIsDaysSinceCollectionCreation() {
        let creation = Date(timeIntervalSince1970: 1_600_000_000)
        let due = ApkgImporter.computeDueDate(due: 10, ivl: 10, type: 2, queue: 2, crt: creation, now: Date())
        let expected = Calendar.current.date(byAdding: .day, value: 10, to: creation)!
        XCTAssertEqual(due.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testLearningDueDateIsATimestamp() {
        let stamp: Int64 = 1_700_000_000
        let due = ApkgImporter.computeDueDate(due: stamp, ivl: 0, type: 1, queue: 1, crt: Date(), now: Date())
        XCTAssertEqual(due.timeIntervalSince1970, TimeInterval(stamp), accuracy: 1)
    }
}

// MARK: - Whole-deck corpus

import SwiftData

/// Imports the bundled sample decks for real and runs the analyzer over every
/// note in them. Unit tests on hand-written strings prove the rules; this proves
/// they hold across 1,749 notes of messy, real-world deck HTML.
final class SampleDeckCorpusTests: XCTestCase {

    @MainActor
    private func importSample(named name: String) throws -> ModelContext {
        let samples = try XCTUnwrap(
            Bundle.main.url(forResource: "samples", withExtension: nil),
            "sample decks are not bundled with the app"
        )
        let file = samples.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "missing \(name)")

        let container = try ModelContainer(
            for: Deck.self, NoteType.self, Note.self, Card.self, ReviewLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let expectation = expectation(description: "import \(name)")
        Task { @MainActor in
            _ = try? await ApkgImporter(modelContext: context).import(from: file)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 120)
        return context
    }

    @MainActor
    private func analyzeAll(_ context: ModelContext) throws -> [CardContent] {
        let notes = try context.fetch(FetchDescriptor<Note>())
        let noteTypes = try context.fetch(FetchDescriptor<NoteType>())
        XCTAssertFalse(notes.isEmpty, "import produced no notes")
        return notes.map { note in
            CardContentAnalyzer.analyze(note: note, noteType: noteTypes.first { $0.ankiId == note.modelId })
        }
    }

    @MainActor
    func testTOEFLDeckParsesIntoWordsAndExamples() throws {
        let context = try importSample(named: "540_MUST_KNOW_WORDS_FOR_TOEFL_IBT.apkg")
        let contents = try analyzeAll(context)

        XCTAssertEqual(contents.count, 540)
        // Every note must yield a headword — that is what gets pronounced.
        XCTAssertTrue(contents.allSatisfy { !$0.headword.isBlank })
        // No headword may still be carrying its part-of-speech suffix.
        XCTAssertFalse(contents.contains { $0.headword.hasSuffix(")") && $0.partOfSpeech != nil })

        let withDefinition = contents.filter { !$0.definitions.isEmpty }.count
        let withExamples = contents.filter { !$0.examples.isEmpty }.count
        XCTAssertEqual(withDefinition, contents.count, "every note in this deck has a Definition field")
        XCTAssertGreaterThan(Double(withExamples) / Double(contents.count), 0.95, "examples found on \(withExamples)/\(contents.count)")

        // Examples must never leak the bullet that separated them.
        XCTAssertFalse(contents.contains { content in
            content.examples.contains { $0.text.unicodeScalars.contains { CardContentAnalyzer.bulletCharacters.contains($0) } }
        })
        // A definition must never carry an unsplit bullet: that would mean an
        // example was left glued to the meaning.
        XCTAssertFalse(contents.contains { content in
            content.definitions.contains { $0.unicodeScalars.contains { CardContentAnalyzer.bulletCharacters.contains($0) } }
        })
    }

    @MainActor
    func testBasicVocabularyDeckParsesIntoWordsAndExamples() throws {
        let context = try importSample(named: "1212 Words.apkg")
        let contents = try analyzeAll(context)

        XCTAssertEqual(contents.count, 1209)
        XCTAssertTrue(contents.allSatisfy { !$0.headword.isBlank })

        let usable = contents.filter { $0.isVocabulary }.count
        XCTAssertGreaterThan(Double(usable) / Double(contents.count), 0.90, "clean layout usable on \(usable)/\(contents.count)")

        // Only 519 of these 1,209 notes mark their examples at all (a list item,
        // italics or a bullet); the rest are a bare gloss like "hire → employ".
        // Finding examples on ~45% of the deck is therefore near the ceiling.
        let withExamples = contents.filter { !$0.examples.isEmpty }.count
        XCTAssertGreaterThan(Double(withExamples) / Double(contents.count), 0.40, "examples found on \(withExamples)/\(contents.count)")

        // Nothing spoken should still contain markup or a raw URL.
        for content in contents.prefix(300) {
            for item in content.answerSpeech {
                let spoken = SpeechService.speakableText(item.text)
                XCTAssertFalse(spoken.contains("<"), "markup leaked into speech: \(spoken.prefix(80))")
                XCTAssertFalse(spoken.contains("http"), "URL leaked into speech: \(spoken.prefix(80))")
            }
        }
    }
}
