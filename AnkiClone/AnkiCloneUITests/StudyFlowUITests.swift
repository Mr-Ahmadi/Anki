import XCTest

/// End-to-end checks of the paths a user actually takes through the app.
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

    /// Without a bundled deck there is nothing to study until the user picks a
    /// file, so this covers the part of the flow the app owns: the import sheet
    /// opens and offers the file picker.
    func testImportSheetOffersFilePicker() throws {
        let decksTab = app.tabBars.buttons["Decks"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 10))
        attachScreenshot("01-launch")

        openImportSheet()

        XCTAssertTrue(app.staticTexts["Import Anki Deck"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Choose File"].exists, "the only way in is picking a file")
        attachScreenshot("02-import-sheet")

        app.buttons["Close"].tap()
        XCTAssertTrue(decksTab.waitForExistence(timeout: 10))
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
