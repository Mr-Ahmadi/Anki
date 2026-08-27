import Foundation
import SwiftData
import ZIPFoundation
import SQLite3

enum ImportError: LocalizedError {
    case invalidFile
    case unzipFailed(String)
    case sqliteOpenFailed
    case sqliteError(String)
    case noCollectionFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Invalid .apkg file"
        case .unzipFailed(let s): return "Failed to unzip: \(s)"
        case .sqliteOpenFailed: return "Failed to open database"
        case .sqliteError(let s): return "Database error: \(s)"
        case .noCollectionFound: return "No collection found in archive"
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
}

// MARK: - ApkgImporter

final class ApkgImporter {

    private let modelContext: ModelContext
    private let fileManager = FileManager.default

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // Main entry — call from background thread, but ModelContext must be used on its actor.
    // We use @MainActor for SwiftData operations.
    @MainActor
    func `import`(from url: URL) async throws -> ImportResult {
        // Security-scoped access for file picker URLs
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Copy to temp if needed
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? fileManager.removeItem(at: tempDir) }

        // Unzip
        try unzipApkg(at: url, to: tempDir)

        // Locate collection file
        let collectionURL = findCollection(in: tempDir)
        guard let collectionURL else { throw ImportError.noCollectionFound }

        // Parse media mapping (if exists)
        let mediaMap = parseMediaMap(in: tempDir)
        // Copy media files to app support
        let mediaDest = try copyMediaFiles(mediaMap: mediaMap, sourceDir: tempDir)

        // Parse SQLite
        let parsed = try parseCollection(at: collectionURL)

        // Import to SwiftData
        return try importParsedData(parsed, mediaDest: mediaDest)
    }

    // MARK: - Unzip

    private func unzipApkg(at sourceURL: URL, to destDir: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw ImportError.invalidFile }

        let archive: Archive
        do {
            archive = try Archive(url: sourceURL, accessMode: .read)
        } catch {
            throw ImportError.unzipFailed("Cannot open archive: \(error.localizedDescription)")
        }

        for entry in archive {
            let destURL = destDir.appendingPathComponent(entry.path)
            // Prevent directory traversal
            guard destURL.path.hasPrefix(destDir.path) else { continue }

            if entry.type == .directory {
                try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }

            // Ensure parent exists
            try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Remove if exists
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }

            do {
                _ = try archive.extract(entry, to: destURL)
            } catch {
                throw ImportError.unzipFailed(error.localizedDescription)
            }
        }
    }

    private func findCollection(in dir: URL) -> URL? {
        let candidates = ["collection.anki21", "collection.anki21b", "collection.anki2"]
        for name in candidates {
            let url = dir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        // fallback: any .anki* file
        if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            return files.first(where: { $0.lastPathComponent.hasPrefix("collection.anki") })
        }
        return nil
    }

    // MARK: - Media

    private func parseMediaMap(in dir: URL) -> [String: String] {
        // media file is JSON: {"0": "image.jpg", "1": "audio.mp3"}
        let mediaURL = dir.appendingPathComponent("media")
        guard let data = try? Data(contentsOf: mediaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private func copyMediaFiles(mediaMap: [String: String], sourceDir: URL) throws -> URL {
        let dest = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AnkiMedia", isDirectory: true)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)

        var copied = 0
        for (key, filename) in mediaMap {
            let src = sourceDir.appendingPathComponent(key)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            // Sanitize filename
            let safeName = filename.replacingOccurrences(of: "/", with: "_")
            let dst = dest.appendingPathComponent(safeName)
            if fileManager.fileExists(atPath: dst.path) {
                try? fileManager.removeItem(at: dst)
            }
            try? fileManager.copyItem(at: src, to: dst)
            copied += 1
        }
        return dest
    }

    // MARK: - SQLite Parsing

    struct ParsedData {
        var decks: [ParsedDeck]
        var models: [ParsedModel]
        var notes: [ParsedNote]
        var cards: [ParsedCard]
        var collectionCreation: Int64 // crt
        var deckConfigs: [String: Any] // dconf
    }

    struct ParsedDeck { let id: Int64; let name: String; let desc: String; let mod: Int64; let collapsed: Bool; let conf: Int64 }
    struct ParsedModel {
        let id: Int64; let name: String; let css: String
        let fieldNames: [String]; let templates: [CardTemplateData]; let sortf: Int
    }
    struct ParsedNote { let id: Int64; let guid: String; let mid: Int64; let mod: Int64; let tags: String; let flds: String; let sfld: String; let csum: Int64 }
    struct ParsedCard { let id: Int64; let nid: Int64; let did: Int64; let ord: Int; let mod: Int64; let type: Int; let queue: Int; let due: Int64; let ivl: Int; let factor: Int; let reps: Int; let lapses: Int; let left: Int; let odue: Int64; let flags: Int; let data: String }

    private func parseCollection(at url: URL) throws -> ParsedData {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw ImportError.sqliteOpenFailed }
        defer { sqlite3_close(db) }

        // Read col table
        var decks: [ParsedDeck] = []
        var models: [ParsedModel] = []
        var crt: Int64 = 0
        var deckConfigs: [String: Any] = [:]

        let colSQL = "SELECT crt, decks, models, dconf FROM col LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, colSQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            crt = sqlite3_column_int64(stmt, 0)
            if let decksText = sqlite3_column_text(stmt, 1) {
                let s = String(cString: decksText)
                decks = parseDecksJSON(s)
            }
            if let modelsText = sqlite3_column_text(stmt, 2) {
                let s = String(cString: modelsText)
                models = parseModelsJSON(s)
            }
            if let dconfText = sqlite3_column_text(stmt, 3) {
                let s = String(cString: dconfText)
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    deckConfigs = obj
                }
            }
        }
        sqlite3_finalize(stmt)

        // Notes
        var notes: [ParsedNote] = []
        var noteStmt: OpaquePointer?
        let noteSQL = "SELECT id, guid, mid, mod, tags, flds, sfld, csum FROM notes;"
        if sqlite3_prepare_v2(db, noteSQL, -1, &noteStmt, nil) == SQLITE_OK {
            while sqlite3_step(noteStmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(noteStmt, 0)
                let guid = String(cString: sqlite3_column_text(noteStmt, 1))
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
            }
        }
        sqlite3_finalize(noteStmt)

        // Cards
        var cards: [ParsedCard] = []
        var cardStmt: OpaquePointer?
        let cardSQL = "SELECT id, nid, did, ord, mod, type, queue, due, ivl, factor, reps, lapses, left, odue, flags, data FROM cards;"
        if sqlite3_prepare_v2(db, cardSQL, -1, &cardStmt, nil) == SQLITE_OK {
            while sqlite3_step(cardStmt) == SQLITE_ROW {
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
            }
        }
        sqlite3_finalize(cardStmt)

        return ParsedData(decks: decks, models: models, notes: notes, cards: cards, collectionCreation: crt, deckConfigs: deckConfigs)
    }

    private func parseDecksJSON(_ json: String) -> [ParsedDeck] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [ParsedDeck] = []
        for (_, v) in dict {
            guard let d = v as? [String: Any],
                  let id = d["id"] as? Int64 ?? (d["id"] as? Int).map(Int64.init) ?? (d["id"] as? NSNumber)?.int64Value
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

    private func parseModelsJSON(_ json: String) -> [ParsedModel] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [ParsedModel] = []
        for (_, v) in dict {
            guard let m = v as? [String: Any],
                  let id = (m["id"] as? NSNumber)?.int64Value ?? (m["id"] as? Int).map(Int64.init)
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
    private func importParsedData(_ parsed: ParsedData, mediaDest: URL) throws -> ImportResult {
        // We need to handle duplicate handling: if deck with same ankiId exists, update or skip?
        // For MVP: skip existing cards/notes by ankiId.

        // Fetch existing IDs to avoid duplicates
        let existingDecks = try modelContext.fetch(FetchDescriptor<Deck>())
        let existingNotes = try modelContext.fetch(FetchDescriptor<Note>())
        let existingCards = try modelContext.fetch(FetchDescriptor<Card>())
        let existingModels = try modelContext.fetch(FetchDescriptor<NoteType>())
        let existingDeckIds = Set(existingDecks.map(\.ankiId))
        let existingNoteIds = Set(existingNotes.map(\.ankiId))
        let existingCardIds = Set(existingCards.map(\.ankiId))
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
            // Filter out Default deck if empty? Keep it.
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
        for n in parsed.notes where !existingNoteIds.contains(n.id) {
            // flds is \u{1f} separated
            let fields = n.flds.components(separatedBy: "\u{1f}")
            let note = Note(ankiId: n.id, guid: n.guid, modelId: n.mid, mod: n.mod, tags: n.tags, fieldValues: fields, sortField: n.sfld, checksum: n.csum)
            modelContext.insert(note)
            noteMap[n.id] = note
            notesImported += 1
        }

        // Import cards
        var cardsImported = 0
        let crtDate = Date(timeIntervalSince1970: TimeInterval(parsed.collectionCreation))
        let now = Date()
        for c in parsed.cards where !existingCardIds.contains(c.id) {
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
            // Link relationships
            card.deck = deckMap[c.did] ?? deckMap.values.first
            card.note = noteMap[c.nid]
            card.deck?.cards.append(card)
            card.note?.cards.append(card)
            modelContext.insert(card)
            cardsImported += 1
        }

        try modelContext.save()

        return ImportResult(
            decksImported: decksImported,
            notesImported: notesImported,
            cardsImported: cardsImported,
            mediaFiles: (try? FileManager.default.contentsOfDirectory(at: mediaDest, includingPropertiesForKeys: nil).count) ?? 0,
            deckNames: parsed.decks.map(\.name)
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
