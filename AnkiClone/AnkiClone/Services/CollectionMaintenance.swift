import Foundation
import SwiftData

/// Deletions that must not rely on SwiftData's cascade rules.
///
/// `Deck.cards` is declared `.cascade`, but SwiftData only propagates that to
/// the rows it has already materialised — deleting a deck whose `cards` array
/// was never faulted in leaves every card behind, still carrying its `ankiId`.
/// The importer then skips those ids as "already imported" and the deck comes
/// back empty, which is exactly what deleting a deck and re-importing the same
/// package used to do. Deleting the rows by hand keeps that from happening.
enum CollectionMaintenance {

    /// Deletes a deck along with its cards and any note left with no cards.
    static func delete(_ deck: Deck, in context: ModelContext) {
        delete(cards: cards(of: deck, in: context), in: context)
        context.delete(deck)
        try? context.save()
        deleteOrphanedNotes(in: context)
    }

    /// Deletes a single card, and its note if that was the note's last card.
    static func delete(card: Card, in context: ModelContext) {
        delete(cards: [card], in: context)
        try? context.save()
        deleteOrphanedNotes(in: context)
    }

    /// Both sides of the deck link, because they can disagree: a card whose
    /// deck id names no imported deck is filed under Default, and a card left
    /// over from an earlier delete has no deck at all.
    private static func cards(of deck: Deck, in context: ModelContext) -> [Card] {
        let deckId = deck.ankiId
        var doomed: [PersistentIdentifier: Card] = [:]
        for card in deck.cards { doomed[card.persistentModelID] = card }
        let byDeckId = FetchDescriptor<Card>(predicate: #Predicate<Card> { $0.deckId == deckId })
        for card in (try? context.fetch(byDeckId)) ?? [] { doomed[card.persistentModelID] = card }
        return Array(doomed.values)
    }

    private static func delete(cards: [Card], in context: ModelContext) {
        for card in cards { context.delete(card) }
    }

    /// A note with no cards can never be studied or browsed, but it would still
    /// be matched by `ankiId` on the next import and its cards rebuilt around a
    /// note the user meant to delete. Clearing them keeps re-import honest and
    /// the library counts truthful.
    static func deleteOrphanedNotes(in context: ModelContext) {
        let liveNoteIds = Set(((try? context.fetch(FetchDescriptor<Card>())) ?? []).map(\.noteId))
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let orphans = notes.filter { !liveNoteIds.contains($0.ankiId) }
        guard !orphans.isEmpty else { return }
        for note in orphans { context.delete(note) }
        try? context.save()
    }
}
