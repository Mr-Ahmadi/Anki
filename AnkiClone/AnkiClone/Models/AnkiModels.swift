import Foundation
import SwiftData

// MARK: - Deck

@Model
final class Deck {
    @Attribute(.unique) var ankiId: Int64
    var name: String
    var desc: String
    var mod: Int64
    var collapsed: Bool
    var createdAt: Date
    var confId: Int64

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \Card.deck)
    var cards: [Card] = []

    init(ankiId: Int64, name: String, desc: String = "", mod: Int64 = 0, collapsed: Bool = false, confId: Int64 = 1) {
        self.ankiId = ankiId
        self.name = name
        self.desc = desc
        self.mod = mod
        self.collapsed = collapsed
        self.createdAt = Date()
        self.confId = confId
    }

    // Computed stats — not persisted, calculated on demand
    var newCount: Int {
        cards.filter { $0.queue == 0 && $0.type == 0 }.count
    }
    var learnCount: Int {
        cards.filter { $0.queue == 1 || $0.queue == 3 }.count
    }
    var dueCount: Int {
        cards.filter { $0.queue == 2 && $0.dueDate <= Date() }.count
    }
    var totalCount: Int { cards.count }

    var displayName: String {
        // Handle Anki's :: subdeck separator
        name.components(separatedBy: "::").last ?? name
    }
    var parentPath: String? {
        let comps = name.components(separatedBy: "::")
        guard comps.count > 1 else { return nil }
        return comps.dropLast().joined(separator: " :: ")
    }
}

// MARK: - NoteType (Anki Model)

@Model
final class NoteType {
    @Attribute(.unique) var ankiId: Int64
    var name: String
    var css: String
    var fieldNames: [String] // ordered
    var templates: [CardTemplateData]
    var sortFieldIndex: Int

    init(ankiId: Int64, name: String, css: String, fieldNames: [String], templates: [CardTemplateData], sortFieldIndex: Int = 0) {
        self.ankiId = ankiId
        self.name = name
        self.css = css
        self.fieldNames = fieldNames
        self.templates = templates
        self.sortFieldIndex = sortFieldIndex
    }
}

struct CardTemplateData: Codable, Hashable {
    var ord: Int
    var name: String
    var qfmt: String
    var afmt: String
    var bqfmt: String?
    var bafmt: String?
}

// MARK: - Note

@Model
final class Note {
    @Attribute(.unique) var ankiId: Int64
    var guid: String
    var modelId: Int64
    var mod: Int64
    var tags: String // space-separated
    var fieldValues: [String] // ordered, matched to NoteType.fieldNames
    var sortField: String
    var checksum: Int64

    @Relationship(deleteRule: .cascade, inverse: \Card.note)
    var cards: [Card] = []

    init(ankiId: Int64, guid: String, modelId: Int64, mod: Int64, tags: String, fieldValues: [String], sortField: String, checksum: Int64) {
        self.ankiId = ankiId
        self.guid = guid
        self.modelId = modelId
        self.mod = mod
        self.tags = tags
        self.fieldValues = fieldValues
        self.sortField = sortField
        self.checksum = checksum
    }

    var tagList: [String] {
        tags.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    func fieldValue(named name: String, noteType: NoteType?) -> String {
        guard let noteType else { return "" }
        guard let idx = noteType.fieldNames.firstIndex(of: name) else { return "" }
        guard idx < fieldValues.count else { return "" }
        return fieldValues[idx]
    }
}

// MARK: - Card

@Model
final class Card {
    @Attribute(.unique) var ankiId: Int64
    var ord: Int // template ordinal
    var mod: Int64
    var type: Int // 0=new, 1=learn, 2=review, 3=relearn
    var queue: Int // 0=new, 1=learn, 2=review, 3=day_learn, -1=suspended, -2=buried
    var due: Int64 // Anki's due value (days or learning steps timestamp)
    var dueDate: Date // computed Date for scheduling
    var interval: Int // days
    var easeFactor: Int // 1300-... (Anki stores *10, e.g. 2500 = 250%)
    var reps: Int
    var lapses: Int
    var left: Int // steps left
    var odue: Int64
    var flags: Int
    var data: String

    // Foreign keys (also relationships)
    var deckId: Int64
    var noteId: Int64

    @Relationship
    var deck: Deck?

    @Relationship
    var note: Note?

    // UI helpers
    var isSuspended: Bool { queue < 0 }
    var isDue: Bool { dueDate <= Date() && queue == 2 }
    var isNew: Bool { type == 0 }

    init(
        ankiId: Int64,
        ord: Int,
        mod: Int64,
        type: Int,
        queue: Int,
        due: Int64,
        dueDate: Date,
        interval: Int,
        easeFactor: Int,
        reps: Int,
        lapses: Int,
        left: Int,
        odue: Int64,
        flags: Int,
        data: String,
        deckId: Int64,
        noteId: Int64
    ) {
        self.ankiId = ankiId
        self.ord = ord
        self.mod = mod
        self.type = type
        self.queue = queue
        self.due = due
        self.dueDate = dueDate
        self.interval = interval
        self.easeFactor = easeFactor
        self.reps = reps
        self.lapses = lapses
        self.left = left
        self.odue = odue
        self.flags = flags
        self.data = data
        self.deckId = deckId
        self.noteId = noteId
    }
}

// MARK: - Review Log (for stats, optional)

@Model
final class ReviewLog {
    var cardId: Int64
    var timestamp: Date
    var ease: Int // 1=again, 2=hard, 3=good, 4=easy
    var interval: Int
    var lastInterval: Int
    var factor: Int
    var timeMs: Int // time taken
    var type: Int

    init(cardId: Int64, ease: Int, interval: Int, lastInterval: Int, factor: Int, timeMs: Int, type: Int) {
        self.cardId = cardId
        self.timestamp = Date()
        self.ease = ease
        self.interval = interval
        self.lastInterval = lastInterval
        self.factor = factor
        self.timeMs = timeMs
        self.type = type
    }
}
