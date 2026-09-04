import Foundation
import SwiftData
import ZIPFoundation
import SQLite3

enum ImportError: LocalizedError {
    case invalidFile
    case unzipFailed(String)
    case sqliteOpenFailed
    case sqliteError(String)
    case noCollectionFound(String)
    case unsupportedPackageFormat
    case emptyCollection
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Invalid .apkg file"
        case .unzipFailed(let s): return "Failed to unzip: \(s)"
        case .sqliteOpenFailed: return "Failed to open database"
        case .sqliteError(let s): return "Database error: \(s)"
        case .noCollectionFound(let contents):
            return contents.isEmpty
                ? "The archive is empty — nothing could be extracted from it."
                : "No collection found in archive. It contains: \(contents)"
        case .unsupportedPackageFormat:
            return "This package uses Anki's newest (compressed) export format, which this app cannot read yet. In Anki Desktop re-export the deck with “Support older Anki versions” checked."
        case .emptyCollection: return "The archive opened, but contains no notes or cards"
        case .cancelled: return "Import cancelled"
        }
    }
}

struct ImportResult {
    var decksImported: Int
    var notesImported: Int
    var cardsImported: Int
    var mediaFiles: Int
    var deckNames: [String]
    /// Rows the package contained that were already in the collection. Notes
    /// and cards are matched on their Anki id, so re-importing is a no-op.
    var notesSkipped: Int = 0
    var cardsSkipped: Int = 0
    /// Cards that were already in the collection but had lost their deck or
    /// note, and were put back where they belong by this import.
    var cardsRelinked: Int = 0

    var notesInPackage: Int { notesImported + notesSkipped }
    var cardsInPackage: Int { cardsImported + cardsSkipped }

    /// The package read fine but added nothing, because all of it was already
    /// imported. That is not the same as a successful import and must not be
    /// reported as one — nor is a repair, which does change the collection.
    var isAlreadyImported: Bool {
        notesImported == 0 && cardsImported == 0 && cardsRelinked == 0
            && (notesSkipped > 0 || cardsSkipped > 0)
    }
}

// MARK: - ApkgImporter

final class ApkgImporter {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Unzipping, media copying and SQLite parsing all happen off the main
    /// actor; only the SwiftData writes run on it. `progress` is called on the
    /// main actor so it can drive the UI.
    func `import`(from url: URL, progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> ImportResult {
        let report: @Sendable (String) -> Void = { message in
            Task { @MainActor in progress(message) }
        }

        // This method is nonisolated, so its body runs on the cooperative pool
        // rather than the caller's actor: unzipping and SQLite never touch main.
        let staged = try Self.stage(url: url, report: report)

        return try await importParsedData(staged.parsed, mediaFiles: staged.mediaFiles, report: report)
    }

    // MARK: - Staging (off the main actor)

    struct StagedCollection: @unchecked Sendable {
        var parsed: ParsedData
        var mediaFiles: Int
    }

    private static func stage(url: URL, report: @Sendable (String) -> Void) throws -> StagedCollection {
        let fileManager = FileManager.default

        // Security-scoped access for file picker URLs.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        report("Unzipping \(url.lastPathComponent)…")
        try unzipApkg(at: url, to: tempDir, report: report)
        try Task.checkCancellation()

        report("Locating collection…")
        guard let collectionURL = try findCollection(in: tempDir) else {
            throw ImportError.noCollectionFound(describeContents(of: tempDir))
        }

        let mediaMap = parseMediaMap(in: tempDir)
        if !mediaMap.isEmpty { report("Copying \(mediaMap.count) media files…") }
        let mediaFiles = copyMediaFiles(mediaMap: mediaMap, sourceDir: tempDir)
        try Task.checkCancellation()

        report("Reading collection…")
        let parsed = try parseCollection(at: collectionURL, report: report)
        guard !parsed.notes.isEmpty || !parsed.cards.isEmpty else { throw ImportError.emptyCollection }

        return StagedCollection(parsed: parsed, mediaFiles: mediaFiles)
    }

    // MARK: - Unzip

    private static func unzipApkg(at sourceURL: URL, to destDir: URL, report: @Sendable (String) -> Void) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw ImportError.invalidFile }

        let archive: Archive
        do {
            archive = try Archive(url: sourceURL, accessMode: .read)
        } catch {
            throw ImportError.unzipFailed("Cannot open archive: \(error.localizedDescription)")
        }

        var extracted = 0
        for entry in archive {
            try Task.checkCancellation()

            guard let destURL = Self.sanitizedDestination(forEntry: entry.path, in: destDir) else { continue }

            if entry.type == .directory {
                try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }

            try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }

            do {
                _ = try archive.extract(entry, to: destURL)
            } catch {
                throw ImportError.unzipFailed(error.localizedDescription)
            }

            extracted += 1
            if extracted % 200 == 0 { report("Unzipping… \(extracted) files") }
        }
    }

    /// Resolves an archive entry to a destination inside `destDir`, rejecting
    /// anything that would escape it.
    ///
    /// Deliberately pure string work. `standardizedFileURL` strips the
    /// `/private` prefix only for paths that already exist, so standardizing
    /// the work directory and comparing it against a not-yet-extracted file
    /// rejects every entry on a real device, where tmp really is under
    /// /private/var — the simulator has no such prefix and never shows it.
    static func sanitizedDestination(forEntry path: String, in destDir: URL) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // ".." could climb out; an absolute entry path is simply re-rooted.
        guard !components.contains("..") else { return nil }
        let meaningful = components.filter { $0 != "." }
        guard !meaningful.isEmpty else { return nil }
        return meaningful.reduce(destDir) { $0.appendingPathComponent($1) }
    }

    /// Picks the first candidate that really is a SQLite database. Anki 2.1.50+
    /// writes `collection.anki21b` as a zstd blob, which SQLite would open
    /// lazily and then fail on every query — that used to look like a hang.
    private static func findCollection(in dir: URL) throws -> URL? {
        let fileManager = FileManager.default
        var candidates = ["collection.anki21", "collection.anki2", "collection.anki21b"]
            .map { dir.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }

        if candidates.isEmpty, let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            candidates = files.filter { $0.lastPathComponent.hasPrefix("collection.anki") }
        }
        // Some packages keep everything inside a folder, so a top-level scan
        // finds nothing. Fall back to walking the tree.
        if candidates.isEmpty, let walker = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) {
            candidates = walker.compactMap { $0 as? URL }
                .filter { $0.lastPathComponent.hasPrefix("collection.anki") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !candidates.isEmpty else { return nil }

        if let usable = candidates.first(where: { isSQLiteDatabase(at: $0) }) { return usable }
        if candidates.contains(where: { isZstdCompressed(at: $0) }) { throw ImportError.unsupportedPackageFormat }
        return nil
    }

    /// Names (and sizes) of what actually landed in the work directory, so a
    /// package we cannot read says why instead of just "no collection found".
    private static func describeContents(of dir: URL) -> String {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return "" }
        let root = dir.path
        return walker.compactMap { $0 as? URL }
            .map { url -> String in
                let relative = url.path.hasPrefix(root)
                    ? String(url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
                    : url.lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return "\(relative) (\(size) bytes)"
            }
            .sorted()
            .prefix(12)
            .joined(separator: ", ")
    }

    private static func header(of url: URL, count: Int) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        return Array((try? handle.read(upToCount: count)) ?? Data())
    }

    private static func isSQLiteDatabase(at url: URL) -> Bool {
        header(of: url, count: 16) == Array("SQLite format 3\0".utf8)
    }

    private static func isZstdCompressed(at url: URL) -> Bool {
        header(of: url, count: 4) == [0x28, 0xB5, 0x2F, 0xFD]
    }

    // MARK: - Media

    private static func parseMediaMap(in dir: URL) -> [String: String] {
        // media file is JSON: {"0": "image.jpg", "1": "audio.mp3"}
        let mediaURL = dir.appendingPathComponent("media")
        guard let data = try? Data(contentsOf: mediaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private static func copyMediaFiles(mediaMap: [String: String], sourceDir: URL) -> Int {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        let dest = support.appendingPathComponent("AnkiMedia", isDirectory: true)
        guard (try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)) != nil else { return 0 }

        var copied = 0
        for (key, filename) in mediaMap {
            let src = sourceDir.appendingPathComponent(key)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            // Sanitize filename
            let safeName = filename.replacingOccurrences(of: "/", with: "_")
            guard !safeName.isEmpty, safeName != ".", safeName != ".." else { continue }
            let dst = dest.appendingPathComponent(safeName)
            if fileManager.fileExists(atPath: dst.path) {
                try? fileManager.removeItem(at: dst)
            }
            if (try? fileManager.copyItem(at: src, to: dst)) != nil { copied += 1 }
        }
        return copied
    }

    // MARK: - SQLite Parsing

    struct ParsedData: Sendable {
        var decks: [ParsedDeck]
        var models: [ParsedModel]
        var notes: [ParsedNote]
        var cards: [ParsedCard]
        var collectionCreation: Int64 // crt
    }

    struct ParsedDeck: Sendable { let id: Int64; let name: String; let desc: String; let mod: Int64; let collapsed: Bool; let conf: Int64 }
    struct ParsedModel: Sendable {
        let id: Int64; let name: String; let css: String
        let fieldNames: [String]; let templates: [CardTemplateData]; let sortf: Int
    }
    struct ParsedNote: Sendable { let id: Int64; let guid: String; let mid: Int64; let mod: Int64; let tags: String; let flds: String; let sfld: String; let csum: Int64 }
    struct ParsedCard: Sendable { let id: Int64; let nid: Int64; let did: Int64; let ord: Int; let mod: Int64; let type: Int; let queue: Int; let due: Int64; let ivl: Int; let factor: Int; let reps: Int; let lapses: Int; let left: Int; let odue: Int64; let flags: Int; let data: String }

    private static func parseCollection(at url: URL, report: @Sendable (String) -> Void) throws -> ParsedData {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ImportError.sqliteOpenFailed
        }
        defer { sqlite3_close(db) }

        func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

        // Read col table
        var decks: [ParsedDeck] = []
        var models: [ParsedModel] = []
        var crt: Int64 = 0

        let colSQL = "SELECT crt, decks, models FROM col LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, colSQL, -1, &stmt, nil) == SQLITE_OK else {
            let message = lastError()
            sqlite3_finalize(stmt)
            throw ImportError.sqliteError(message)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            crt = sqlite3_column_int64(stmt, 0)
            if let decksText = sqlite3_column_text(stmt, 1) {
                decks = parseDecksJSON(String(cString: decksText))
            }
            if let modelsText = sqlite3_column_text(stmt, 2) {
                models = parseModelsJSON(String(cString: modelsText))
            }
        }
        sqlite3_finalize(stmt)

        // Newer collections keep decks/notetypes in their own tables and leave
        // the legacy JSON columns empty.
        if decks.isEmpty { decks = parseDeckTable(db) }

        // Notes
        var notes: [ParsedNote] = []
        var noteStmt: OpaquePointer?
        let noteSQL = "SELECT id, guid, mid, mod, tags, flds, sfld, csum FROM notes;"
        guard sqlite3_prepare_v2(db, noteSQL, -1, &noteStmt, nil) == SQLITE_OK else {
            let message = lastError()
            sqlite3_finalize(noteStmt)
            throw ImportError.sqliteError(message)
        }
        while sqlite3_step(noteStmt) == SQLITE_ROW {
            try Task.checkCancellation()
            let id = sqlite3_column_int64(noteStmt, 0)
            let guid = sqlite3_column_text(noteStmt, 1).map { String(cString: $0) } ?? ""
            let mid = sqlite3_column_int64(noteStmt, 2)
            let mod = sqlite3_column_int64(noteStmt, 3)
            let tags = sqlite3_column_text(noteStmt, 4).map { String(cString: $0) } ?? ""
            let flds = sqlite3_column_text(noteStmt, 5).map { String(cString: $0) } ?? ""
            let sfld: String
            if sqlite3_column_type(noteStmt, 6) == SQLITE_TEXT {
                sfld = String(cString: sqlite3_column_text(noteStmt, 6))
            } else {
                sfld = "\(sqlite3_column_int64(noteStmt, 6))"
            }
            let csum = sqlite3_column_int64(noteStmt, 7)
            notes.append(ParsedNote(id: id, guid: guid, mid: mid, mod: mod, tags: tags, flds: flds, sfld: sfld, csum: csum))
            if notes.count % 1000 == 0 { report("Read \(notes.count) notes…") }
        }
        sqlite3_finalize(noteStmt)

        // Cards
        var cards: [ParsedCard] = []
        var cardStmt: OpaquePointer?
        let cardSQL = "SELECT id, nid, did, ord, mod, type, queue, due, ivl, factor, reps, lapses, left, odue, flags, data FROM cards;"
        guard sqlite3_prepare_v2(db, cardSQL, -1, &cardStmt, nil) == SQLITE_OK else {
            let message = lastError()
            sqlite3_finalize(cardStmt)
            throw ImportError.sqliteError(message)
        }
        while sqlite3_step(cardStmt) == SQLITE_ROW {
            try Task.checkCancellation()
            let id = sqlite3_column_int64(cardStmt, 0)
            let nid = sqlite3_column_int64(cardStmt, 1)
            let did = sqlite3_column_int64(cardStmt, 2)
            let ord = Int(sqlite3_column_int(cardStmt, 3))
            let mod = sqlite3_column_int64(cardStmt, 4)
            let type = Int(sqlite3_column_int(cardStmt, 5))
            let queue = Int(sqlite3_column_int(cardStmt, 6))
            let due = sqlite3_column_int64(cardStmt, 7)
            let ivl = Int(sqlite3_column_int(cardStmt, 8))
            let factor = Int(sqlite3_column_int(cardStmt, 9))
            let reps = Int(sqlite3_column_int(cardStmt, 10))
            let lapses = Int(sqlite3_column_int(cardStmt, 11))
            let left = Int(sqlite3_column_int(cardStmt, 12))
            let odue = sqlite3_column_int64(cardStmt, 13)
            let flags = Int(sqlite3_column_int(cardStmt, 14))
            let data = sqlite3_column_text(cardStmt, 15).map { String(cString: $0) } ?? ""
            cards.append(ParsedCard(id: id, nid: nid, did: did, ord: ord, mod: mod, type: type, queue: queue, due: due, ivl: ivl, factor: factor, reps: reps, lapses: lapses, left: left, odue: odue, flags: flags, data: data))
            if cards.count % 1000 == 0 { report("Read \(cards.count) cards…") }
        }
        sqlite3_finalize(cardStmt)

        return ParsedData(decks: decks, models: models, notes: notes, cards: cards, collectionCreation: crt)
    }

    /// Anki 2.1.28+ moved decks into a real table; the `col.decks` JSON blob is
    /// then "{}" and we would otherwise import everything into one Default deck.
    private static func parseDeckTable(_ db: OpaquePointer) -> [ParsedDeck] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, mtime_secs FROM decks;", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var out: [ParsedDeck] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            // The table stores subdeck separators as \u{1f}, not "::".
            let raw = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Deck \(id)"
            let name = raw.replacingOccurrences(of: "\u{1f}", with: "::")
            let mod = sqlite3_column_int64(stmt, 2)
            out.append(ParsedDeck(id: id, name: name, desc: "", mod: mod, collapsed: false, conf: 1))
        }
        return out
    }

    private static func parseDecksJSON(_ json: String) -> [ParsedDeck] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [ParsedDeck] = []
        for (_, v) in dict {
            guard let d = v as? [String: Any],
                  let id = (d["id"] as? NSNumber)?.int64Value
            else { continue }
            let name = d["name"] as? String ?? "Deck \(id)"
            let desc = d["desc"] as? String ?? ""
            let mod = (d["mod"] as? NSNumber)?.int64Value ?? 0
            let collapsed = d["collapsed"] as? Bool ?? false
            let conf = (d["conf"] as? NSNumber)?.int64Value ?? 1
            out.append(ParsedDeck(id: id, name: name, desc: desc, mod: mod, collapsed: collapsed, conf: conf))
        }
        return out
    }

    private static func parseModelsJSON(_ json: String) -> [ParsedModel] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [ParsedModel] = []
        for (_, v) in dict {
            guard let m = v as? [String: Any],
                  let id = (m["id"] as? NSNumber)?.int64Value
            else { continue }
            let name = m["name"] as? String ?? "Model \(id)"
            let css = m["css"] as? String ?? ""
            let sortf = (m["sortf"] as? NSNumber)?.intValue ?? 0

            var fieldNames: [String] = []
            if let flds = m["flds"] as? [[String: Any]] {
                fieldNames = flds.sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                    .compactMap { $0["name"] as? String }
            }

            var templates: [CardTemplateData] = []
            if let tmpls = m["tmpls"] as? [[String: Any]] {
                for t in tmpls {
                    let ord = t["ord"] as? Int ?? templates.count
                    let tname = t["name"] as? String ?? "Card \(ord+1)"
                    let qfmt = t["qfmt"] as? String ?? "{{Front}}"
                    let afmt = t["afmt"] as? String ?? "{{FrontSide}}<hr>{{Back}}"
                    templates.append(CardTemplateData(ord: ord, name: tname, qfmt: qfmt, afmt: afmt, bqfmt: t["bqfmt"] as? String, bafmt: t["bafmt"] as? String))
                }
            }
            out.append(ParsedModel(id: id, name: name, css: css, fieldNames: fieldNames, templates: templates, sortf: sortf))
        }
        return out
    }

    // MARK: - Import to SwiftData

    @MainActor
    private func importParsedData(
        _ parsed: ParsedData,
        mediaFiles: Int,
        report: @Sendable (String) -> Void
    ) async throws -> ImportResult {
        // Existing rows are skipped by ankiId, so re-importing a deck is a no-op.
        let existingDecks = try modelContext.fetch(FetchDescriptor<Deck>())
        let existingNotes = try modelContext.fetch(FetchDescriptor<Note>())
        let existingModels = try modelContext.fetch(FetchDescriptor<NoteType>())
        var existingCards: [Int64: Card] = [:]
        for card in try modelContext.fetch(FetchDescriptor<Card>()) { existingCards[card.ankiId] = card }
        let existingDeckIds = Set(existingDecks.map(\.ankiId))
        let existingNoteIds = Set(existingNotes.map(\.ankiId))
        let existingModelIds = Set(existingModels.map(\.ankiId))

        // Import models
        var modelMap: [Int64: NoteType] = [:]
        for nt in existingModels { modelMap[nt.ankiId] = nt }
        for m in parsed.models where !existingModelIds.contains(m.id) {
            let nt = NoteType(ankiId: m.id, name: m.name, css: m.css, fieldNames: m.fieldNames, templates: m.templates, sortFieldIndex: m.sortf)
            modelContext.insert(nt)
            modelMap[m.id] = nt
        }

        // Import decks
        var deckMap: [Int64: Deck] = [:]
        for d in existingDecks { deckMap[d.ankiId] = d }
        var decksImported = 0
        for d in parsed.decks where !existingDeckIds.contains(d.id) {
            let deck = Deck(ankiId: d.id, name: d.name, desc: d.desc, mod: d.mod, collapsed: d.collapsed, confId: d.conf)
            modelContext.insert(deck)
            deckMap[d.id] = deck
            decksImported += 1
        }
        // Ensure at least one deck exists for orphan cards — use Default
        if deckMap.isEmpty {
            let def = Deck(ankiId: 1, name: "Default", desc: "")
            modelContext.insert(def)
            deckMap[1] = def
            decksImported += 1
        }

        // Import notes
        var noteMap: [Int64: Note] = [:]
        for n in existingNotes { noteMap[n.ankiId] = n }
        var notesImported = 0
        let newNotes = parsed.notes.filter { !existingNoteIds.contains($0.id) }
        for n in newNotes {
            try Task.checkCancellation()
            // flds is \u{1f} separated
            let fields = n.flds.components(separatedBy: "\u{1f}")
            let note = Note(ankiId: n.id, guid: n.guid, modelId: n.mid, mod: n.mod, tags: n.tags, fieldValues: fields, sortField: n.sfld, checksum: n.csum)
            modelContext.insert(note)
            noteMap[n.id] = note
            notesImported += 1
            if notesImported % 250 == 0 {
                report("Saving notes… \(notesImported)/\(newNotes.count)")
                await Task.yield()
            }
        }

        // Import cards
        var cardsImported = 0
        let crtDate = Date(timeIntervalSince1970: TimeInterval(parsed.collectionCreation))
        let now = Date()
        let fallbackDeck = deckMap[1] ?? deckMap.values.first
        var cardsByDeck: [Int64: [Card]] = [:]

        // A card already in the collection can have lost the deck it belonged
        // to — deleting a deck leaves its cards behind — and re-importing would
        // then skip it by id and rebuild the deck empty. Reattach it instead.
        var cardsRelinked = 0
        for c in parsed.cards {
            guard let existing = existingCards[c.id] else { continue }
            let target = deckMap[c.did] ?? fallbackDeck
            if existing.note == nil { existing.note = noteMap[c.nid] }
            guard existing.deck == nil || existing.deck?.ankiId != target?.ankiId else { continue }
            cardsByDeck[target?.ankiId ?? 1, default: []].append(existing)
            cardsRelinked += 1
        }
        if cardsRelinked > 0 { report("Restoring \(cardsRelinked) cards…") }

        let newCards = parsed.cards.filter { existingCards[$0.id] == nil }
        for c in newCards {
            try Task.checkCancellation()
            let dueDate = Self.computeDueDate(due: c.due, ivl: c.ivl, type: c.type, queue: c.queue, crt: crtDate, now: now)
            let card = Card(
                ankiId: c.id,
                ord: c.ord,
                mod: c.mod,
                type: c.type,
                queue: c.queue,
                due: c.due,
                dueDate: dueDate,
                interval: c.ivl,
                easeFactor: c.factor,
                reps: c.reps,
                lapses: c.lapses,
                left: c.left,
                odue: c.odue,
                flags: c.flags,
                data: c.data,
                deckId: c.did,
                noteId: c.nid
            )
            modelContext.insert(card)
            card.note = noteMap[c.nid]
            // The deck side is filled in one batch below: assigning card.deck
            // per card re-materialises the deck's whole cards array each time,
            // which is what made a few thousand cards take minutes.
            cardsByDeck[(deckMap[c.did] ?? fallbackDeck)?.ankiId ?? 1, default: []].append(card)
            cardsImported += 1
            if cardsImported % 250 == 0 {
                report("Saving cards… \(cardsImported)/\(newCards.count)")
                await Task.yield()
            }
        }

        for (deckId, cards) in cardsByDeck {
            deckMap[deckId]?.cards.append(contentsOf: cards)
        }

        report("Finishing…")
        try modelContext.save()

        return ImportResult(
            decksImported: decksImported,
            notesImported: notesImported,
            cardsImported: cardsImported,
            mediaFiles: mediaFiles,
            deckNames: parsed.decks.map(\.name),
            notesSkipped: parsed.notes.count - notesImported,
            cardsSkipped: parsed.cards.count - cardsImported,
            cardsRelinked: cardsRelinked
        )
    }

    // Anki due logic: for new cards, due is position; for learn, due is timestamp (seconds); for review, due is days since crt.
    static func computeDueDate(due: Int64, ivl: Int, type: Int, queue: Int, crt: Date, now: Date) -> Date {
        switch type {
        case 0: // new
            // New cards sorted by due order — not yet due, treat as now
            return now
        case 1, 3: // learn / relearn — due is unix timestamp (seconds)
            if due > 1_000_000_000 { // heuristic: large due = timestamp
                return Date(timeIntervalSince1970: TimeInterval(due))
            } else if due > 0 {
                // Sometimes stored as seconds since epoch? Already handled
                return Date(timeIntervalSince1970: TimeInterval(due))
            } else {
                return now.addingTimeInterval(60)
            }
        case 2: // review — due is days since crt
            let days = Int(due)
            if let date = Calendar.current.date(byAdding: .day, value: days, to: crt) {
                // If due date is in past, it's due now; if future, that's its due date
                return date
            }
            return now
        default:
            return now
        }
    }
}
