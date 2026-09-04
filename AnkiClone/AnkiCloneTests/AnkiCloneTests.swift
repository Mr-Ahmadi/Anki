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

// MARK: - Whole-package import

import SwiftData
import SQLite3
import ZIPFoundation

/// Drives the importer over a real `.apkg` built on the fly, so the zip, the
/// SQLite read and the SwiftData write are all exercised without shipping a
/// deck inside the app.
final class ApkgImportTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Fixtures

    /// Writes a legacy (uncompressed) collection with `noteCount` Basic notes,
    /// one card each, split across two decks.
    private func makeCollection(noteCount: Int, at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE col (id integer primary key, crt integer, decks text, models text, dconf text);")
        try exec("CREATE TABLE notes (id integer primary key, guid text, mid integer, mod integer, tags text, flds text, sfld text, csum integer);")
        try exec("CREATE TABLE cards (id integer primary key, nid integer, did integer, ord integer, mod integer, type integer, queue integer, due integer, ivl integer, factor integer, reps integer, lapses integer, left integer, odue integer, flags integer, data text);")

        let decks = """
        {"1":{"id":1,"name":"Default","desc":"","mod":0,"conf":1},\
        "1600000000000":{"id":1600000000000,"name":"Vocab::Unit 1","desc":"unit one","mod":0,"conf":1}}
        """
        let models = """
        {"1500000000000":{"id":1500000000000,"name":"Basic","css":".card{}","sortf":0,\
        "flds":[{"name":"Front","ord":0},{"name":"Back","ord":1}],\
        "tmpls":[{"ord":0,"name":"Card 1","qfmt":"{{Front}}","afmt":"{{FrontSide}}<hr>{{Back}}"}]}}
        """
        try exec("INSERT INTO col (id, crt, decks, models, dconf) VALUES (1, 1600000000, '\(decks)', '\(models)', '{}');")

        for i in 0..<noteCount {
            let noteId = 1_700_000_000_000 + Int64(i)
            let deckId = i % 2 == 0 ? 1_600_000_000_000 : 1
            try exec("""
            INSERT INTO notes VALUES (\(noteId), 'guid\(i)', 1500000000000, 0, '', 'front \(i)\u{1f}back \(i)', 'front \(i)', 0);
            """)
            try exec("""
            INSERT INTO cards VALUES (\(noteId + 1), \(noteId), \(deckId), 0, 0, 0, 0, \(i), 0, 2500, 0, 0, 0, 0, 0, '');
            """)
        }
    }

    /// Zips `files` (name → contents on disk) into an .apkg.
    private func makePackage(named name: String, files: [String: URL]) throws -> URL {
        let packageURL = workDir.appendingPathComponent(name)
        let archive = try Archive(url: packageURL, accessMode: .create)
        for (entryName, source) in files {
            let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            try archive.addEntry(with: entryName, type: .file, uncompressedSize: Int64(size)) { position, requested in
                try handle.seek(toOffset: UInt64(position))
                return try handle.read(upToCount: requested) ?? Data()
            }
        }
        return packageURL
    }

    @MainActor
    private func freshContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Deck.self, NoteType.self, Note.self, Card.self, ReviewLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: Tests

    @MainActor
    func testImportsDecksNotesAndCardsAndLinksThem() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 40, at: collection)
        let package = try makePackage(named: "deck.apkg", files: ["collection.anki2": collection])

        let context = try freshContext()
        let result = try await ApkgImporter(modelContext: context).import(from: package)

        XCTAssertEqual(result.decksImported, 2)
        XCTAssertEqual(result.notesImported, 40)
        XCTAssertEqual(result.cardsImported, 40)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertEqual(cards.count, 40)
        XCTAssertTrue(cards.allSatisfy { $0.note != nil }, "every card must reach its note")
        XCTAssertTrue(cards.allSatisfy { $0.deck != nil }, "every card must land in a deck")

        // The inverse relationship must be populated exactly once per card —
        // the importer used to append to it by hand on top of SwiftData.
        let decks = try context.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.reduce(0) { $0 + $1.cards.count }, 40)
        let unit = try XCTUnwrap(decks.first { $0.name == "Vocab::Unit 1" })
        XCTAssertEqual(unit.cards.count, 20)
        XCTAssertEqual(unit.displayName, "Unit 1")
    }

    @MainActor
    func testReimportingTheSamePackageAddsNothing() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 10, at: collection)
        let package = try makePackage(named: "deck.apkg", files: ["collection.anki2": collection])

        let context = try freshContext()
        let importer = ApkgImporter(modelContext: context)
        let first = try await importer.import(from: package)
        let second = try await importer.import(from: package)

        XCTAssertEqual(second.notesImported, 0)
        XCTAssertEqual(second.cardsImported, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).count, 10)

        // Nothing was added, so this must not be reported as a fresh import —
        // a success screen reading 0/0/0 is what made this look like a failure.
        XCTAssertTrue(second.isAlreadyImported)
        XCTAssertEqual(second.notesSkipped, 10)
        XCTAssertEqual(second.cardsSkipped, 10)
        XCTAssertEqual(second.notesInPackage, 10)

        XCTAssertFalse(first.isAlreadyImported, "the first import really did add cards")
        XCTAssertEqual(first.notesSkipped, 0)
    }

    /// Deleting a deck and re-importing the very same package used to bring
    /// the deck back empty: SwiftData left the cards in the store, so the
    /// importer matched their ids and skipped every one of them.
    @MainActor
    func testReimportingAfterDeletingTheDeckRestoresItsCards() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 10, at: collection)
        let package = try makePackage(named: "deck.apkg", files: ["collection.anki2": collection])

        let context = try freshContext()
        _ = try await ApkgImporter(modelContext: context).import(from: package)

        for deck in try context.fetch(FetchDescriptor<Deck>()) {
            CollectionMaintenance.delete(deck, in: context)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).count, 0, "deleting a deck must take its cards with it")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 0, "notes left with no cards must go too")

        let second = try await ApkgImporter(modelContext: context).import(from: package)
        XCTAssertEqual(second.notesImported, 10)
        XCTAssertEqual(second.cardsImported, 10)
        XCTAssertFalse(second.isAlreadyImported)

        let decks = try context.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.reduce(0) { $0 + $1.cards.count }, 10)
        let unit = try XCTUnwrap(decks.first { $0.name == "Vocab::Unit 1" })
        XCTAssertEqual(unit.cards.count, 5)
    }

    /// The repair path, for collections already left in the broken state by a
    /// delete that ran before the fix: the cards are still there but belong to
    /// no deck, and re-importing has to adopt them rather than skip them.
    @MainActor
    func testReimportAdoptsCardsThatLostTheirDeck() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 10, at: collection)
        let package = try makePackage(named: "deck.apkg", files: ["collection.anki2": collection])

        let context = try freshContext()
        _ = try await ApkgImporter(modelContext: context).import(from: package)

        // Exactly what the old `modelContext.delete(deck)` left behind.
        for deck in try context.fetch(FetchDescriptor<Deck>()) {
            for card in deck.cards { card.deck = nil }
            context.delete(deck)
        }
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).count, 10)

        let second = try await ApkgImporter(modelContext: context).import(from: package)
        XCTAssertEqual(second.cardsImported, 0, "the cards were already there")
        XCTAssertEqual(second.cardsRelinked, 10)
        XCTAssertFalse(second.isAlreadyImported, "a repair changed the collection; it is not a no-op")

        let decks = try context.fetch(FetchDescriptor<Deck>())
        XCTAssertEqual(decks.reduce(0) { $0 + $1.cards.count }, 10)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Card>()).allSatisfy { $0.deck != nil })
    }

    /// Deleting one card must not strand its note — a note with no cards is
    /// invisible, yet would still be matched by id on the next import.
    @MainActor
    func testDeletingACardRemovesItsNowEmptyNote() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 3, at: collection)
        let package = try makePackage(named: "deck.apkg", files: ["collection.anki2": collection])

        let context = try freshContext()
        _ = try await ApkgImporter(modelContext: context).import(from: package)

        let card = try XCTUnwrap(try context.fetch(FetchDescriptor<Card>()).first)
        CollectionMaintenance.delete(card: card, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 2)
    }

    /// A zstd collection is what Anki 2.1.50+ writes without legacy support.
    /// SQLite opens it lazily and then fails every query, which used to leave
    /// the import sitting on "Importing…"; it has to surface as an error.
    @MainActor
    func testCompressedCollectionReportsUnsupportedFormat() async throws {
        let collection = workDir.appendingPathComponent("collection.anki21b")
        try Data([0x28, 0xB5, 0x2F, 0xFD] + Array(repeating: 0, count: 64)).write(to: collection)
        let package = try makePackage(named: "new.apkg", files: ["collection.anki21b": collection])

        let context = try freshContext()
        do {
            _ = try await ApkgImporter(modelContext: context).import(from: package)
            XCTFail("a zstd collection must not import silently")
        } catch ImportError.unsupportedPackageFormat {
            // expected
        }
    }

    // MARK: Entry path sanitising

    /// Reproduces the device failure. The work directory exists and is reached
    /// through /private; the file about to be extracted does not exist yet.
    /// `standardizedFileURL` strips the /private prefix only for the former, so
    /// a guard that standardises both sides rejects every entry — the app
    /// extracted nothing and reported the archive as empty. The simulator's
    /// temp directory has no /private prefix, which is why this only ever
    /// showed up on a real phone.
    func testDestinationIsUnaffectedByPrivatePrefixStandardisation() throws {
        let work = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try XCTSkipUnless(
            (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
            "cannot write to /private/tmp here"
        )
        defer { try? FileManager.default.removeItem(at: work) }

        let child = work.appendingPathComponent("collection.anki2")
        // The asymmetry itself — skip rather than fail if the platform ever
        // stops behaving this way, since the point is the sanitiser's immunity.
        try XCTSkipUnless(work.standardizedFileURL.path != work.path, "/private not stripped on this platform")
        XCTAssertFalse(
            child.standardizedFileURL.path.hasPrefix(work.standardizedFileURL.path),
            "this is the comparison that used to reject every archive entry"
        )

        let dest = try XCTUnwrap(ApkgImporter.sanitizedDestination(forEntry: "collection.anki2", in: work))
        XCTAssertEqual(dest.path, child.path, "the destination must not depend on what exists on disk")
    }

    func testEntryPathsAreSanitised() throws {
        let root = URL(fileURLWithPath: "/work", isDirectory: true)
        func dest(_ entry: String) -> String? { ApkgImporter.sanitizedDestination(forEntry: entry, in: root)?.path }

        XCTAssertEqual(dest("media"), "/work/media")
        XCTAssertEqual(dest("My Deck/collection.anki2"), "/work/My Deck/collection.anki2")
        // An absolute entry path is re-rooted inside the work directory.
        XCTAssertEqual(dest("/etc/passwd"), "/work/etc/passwd")
        // Anything that could climb out is refused outright.
        XCTAssertNil(dest("../escape"))
        XCTAssertNil(dest("a/../../escape"))
        XCTAssertNil(dest(""))
        XCTAssertNil(dest("."))
    }

    /// Packages that keep their files inside a folder must still import; a
    /// top-level-only scan reports "no collection found" on these.
    @MainActor
    func testCollectionNestedInAFolderIsFound() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 6, at: collection)
        let package = try makePackage(named: "nested.apkg", files: ["My Deck/collection.anki2": collection])

        let context = try freshContext()
        let result = try await ApkgImporter(modelContext: context).import(from: package)
        XCTAssertEqual(result.notesImported, 6)
        XCTAssertEqual(result.cardsImported, 6)
    }

    @MainActor
    func testArchiveWithoutACollectionReportsAnError() async throws {
        let stray = workDir.appendingPathComponent("readme.txt")
        try Data("nothing to see".utf8).write(to: stray)
        let package = try makePackage(named: "empty.apkg", files: ["readme.txt": stray])

        let context = try freshContext()
        do {
            _ = try await ApkgImporter(modelContext: context).import(from: package)
            XCTFail("an archive with no collection must not import silently")
        } catch ImportError.noCollectionFound(let contents) {
            // The message must name what was actually in the archive.
            XCTAssertTrue(contents.contains("readme.txt"), "got: \(contents)")
        }
    }

    /// The progress callback is what the import screen renders; if it never
    /// fires the user just sees a spinner.
    @MainActor
    func testProgressIsReported() async throws {
        let collection = workDir.appendingPathComponent("collection.anki2")
        try makeCollection(noteCount: 600, at: collection)
        let package = try makePackage(named: "deck.apkg", files: ["collection.anki2": collection])

        let messages = Messages()
        let context = try freshContext()
        _ = try await ApkgImporter(modelContext: context).import(from: package) { messages.append($0) }

        // Progress hops to the main actor, so let the queued updates land.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(messages.all.isEmpty, "the import must report progress")
        XCTAssertTrue(messages.all.contains { $0.hasPrefix("Reading collection") })
    }

    @MainActor
    private final class Messages {
        private(set) var all: [String] = []
        func append(_ message: String) { all.append(message) }
    }
}
