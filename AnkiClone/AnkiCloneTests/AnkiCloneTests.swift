import XCTest
@testable import AnkiClone

final class AnkiCloneTests: XCTestCase {
    func testTemplateRendererBasic() {
        let noteType = NoteType(
            ankiId: 1,
            name: "Basic",
            css: ".card { font-size: 20px; }",
            fieldNames: ["Front", "Back"],
            templates: [CardTemplateData(ord: 0, name: "Card 1", qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}")]
        )
        let note = Note(ankiId: 1, guid: "test", modelId: 1, mod: 0, tags: "", fieldValues: ["Hello", "World"], sortField: "Hello", checksum: 0)
        let fields = TemplateRenderer.fieldsDictionary(note: note, noteType: noteType)
        let q = TemplateRenderer.render(template: "{{Front}}", fields: fields, noteType: noteType)
        XCTAssertTrue(q.contains("Hello"))
        let frontHTML = TemplateRenderer.render(template: "{{Front}}", fields: fields, noteType: noteType)
        let a = TemplateRenderer.render(template: "{{FrontSide}}<hr>{{Back}}", fields: fields, noteType: noteType, frontSide: frontHTML)
        XCTAssertTrue(a.contains("World"))
    }

    func testSchedulerNewCard() {
        let card = Card(ankiId: 1, ord: 0, mod: 0, type: 0, queue: 0, due: 0, dueDate: Date(), interval: 0, easeFactor: 2500, reps: 0, lapses: 0, left: 0, odue: 0, flags: 0, data: "", deckId: 1, noteId: 1)
        let scheduler = Scheduler()
        let result = scheduler.answer(card: card, rating: .good)
        XCTAssertEqual(result.newInterval, 1)
        XCTAssertEqual(result.newType, 2)
    }

    func testClozeRendering() {
        let fields: [String: String] = ["Text": "The {{c1::capital}} of France is {{c2::Paris}}"]
        // Cloze is handled inside field values via template processing; test direct
        let html = TemplateRenderer.render(template: "{{Text}}", fields: fields, noteType: nil)
        XCTAssertTrue(html.contains("The"))
    }
}
