import XCTest

/// End-to-end check of the path a user actually takes: import a deck, open it,
/// reveal an answer, and use the separated word / example playback.
final class StudyFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also drop a PNG in the runner's Documents folder so the shots can be
        // reviewed directly instead of digging through the result bundle.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? screenshot.pngRepresentation.write(to: documents.appendingPathComponent("\(name).png"))
        }
    }

    func testImportSampleThenStudyACard() throws {
        // --- Import ------------------------------------------------------
        let decksTab = app.tabBars.buttons["Decks"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 10))
        attachScreenshot("01-launch")

        openImportSheet()

        let sample = app.buttons["540_MUST_KNOW_WORDS_FOR_TOEFL_IBT"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10), "bundled sample deck should be offered")
        sample.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 120), "import should finish")
        attachScreenshot("02-imported")
        done.tap()

        // --- Open the deck ----------------------------------------------
        let deckRow = app.buttons.matching(identifier: "deck.row").firstMatch
        XCTAssertTrue(deckRow.waitForExistence(timeout: 15), "an imported deck should appear")
        attachScreenshot("03-deck-list")
        deckRow.tap()

        // --- Question side ----------------------------------------------
        let showAnswer = app.buttons["card.showAnswer"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 15), "study screen should show a question")
        XCTAssertTrue(app.buttons["card.speakWord"].exists, "the word must be pronounceable on its own")
        attachScreenshot("04-question")

        showAnswer.tap()

        // --- Answer side -------------------------------------------------
        XCTAssertTrue(app.buttons["rating.good"].waitForExistence(timeout: 10), "rating buttons should appear")
        XCTAssertTrue(app.staticTexts["MEANING"].exists, "the meaning should be its own section")
        XCTAssertTrue(app.buttons["card.speakWord"].exists, "the word stays separately playable on the answer")
        attachScreenshot("05-answer")

        // --- Answering advances the queue --------------------------------
        app.buttons["rating.good"].tap()
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 10), "the next card should be face down")
        attachScreenshot("06-next-card")
    }

    /// The TOEFL deck carries a phonetic respelling, a part of speech and a
    /// Persian translation — each of which belongs in its own place, and only
    /// one of which should be spoken by the English voice.
    func testVocabularyCardSeparatesItsParts() throws {
        if app.buttons.matching(identifier: "deck.row").count == 0 {
            openImportSheet()
            let sample = app.buttons["540_MUST_KNOW_WORDS_FOR_TOEFL_IBT"]
            XCTAssertTrue(sample.waitForExistence(timeout: 10))
            sample.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 120))
            done.tap()
        }

        let toefl = app.buttons.matching(identifier: "deck.row")
            .containing(NSPredicate(format: "label CONTAINS[c] '540'")).firstMatch
        XCTAssertTrue(toefl.waitForExistence(timeout: 15))
        toefl.tap()

        XCTAssertTrue(app.buttons["card.showAnswer"].waitForExistence(timeout: 15))
        attachScreenshot("08-toefl-question")
        app.buttons["card.showAnswer"].tap()

        XCTAssertTrue(app.buttons["rating.good"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["MEANING"].exists, "the meaning is its own section")
        XCTAssertTrue(app.buttons["card.speakWord"].exists, "the word is pronounceable on its own")

        // Not every note carries example sentences, so walk forward until one does.
        var examplesFound = app.staticTexts["EXAMPLES"].exists
        var attempts = 0
        while !examplesFound && attempts < 6 {
            app.buttons["rating.good"].tap()
            XCTAssertTrue(app.buttons["card.showAnswer"].waitForExistence(timeout: 10))
            app.buttons["card.showAnswer"].tap()
            XCTAssertTrue(app.buttons["rating.good"].waitForExistence(timeout: 10))
            examplesFound = app.staticTexts["EXAMPLES"].exists
            attempts += 1
        }
        XCTAssertTrue(examplesFound, "examples should be their own section on a vocabulary card")
        XCTAssertTrue(app.buttons["card.playAllExamples"].exists, "examples should be playable as a group")
        attachScreenshot("09-toefl-answer")

        // Playing the examples must not disturb the card.
        app.buttons["card.playAllExamples"].tap()
        XCTAssertTrue(app.buttons["rating.good"].exists)
    }

    func testPronunciationSettingsAreReachable() throws {
        app.tabBars.buttons["Settings"].tap()
        let voice = app.descendants(matching: .any)["settings.pronunciation"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()
        XCTAssertTrue(app.staticTexts["Word speed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sentence speed"].exists, "words and sentences have separate speeds")
        attachScreenshot("07-pronunciation-settings")
    }

    private func openImportSheet() {
        // The deck list offers import from its empty state and from the toolbar.
        let emptyStateImport = app.buttons["Import .apkg / .colpkg"]
        if emptyStateImport.waitForExistence(timeout: 5) {
            emptyStateImport.tap()
            return
        }
        app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1).tap()
        app.buttons["Import deck…"].tap()
    }
}
