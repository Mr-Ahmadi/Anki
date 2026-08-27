# AnkiClone — iOS Replacement for Anki

A native iOS app that is **fully compatible with Anki `.apkg` / `.colpkg` files**. Import decks from Anki Desktop, AnkiWeb, or shared decks and study them with an Anki-accurate scheduler, HTML template rendering, and media support.

Built with **SwiftUI + SwiftData + SQLite** — no server required, 100% on-device.

## Screenshots (Simulator)

- **Decks** — hierarchical deck list with new/learn/due pills, swipe actions, empty state
- **Study** — card flip, Again/Hard/Good/Easy with interval previews, learning re-queue, bury/suspend
- **Browse** — search cards/notes/tags, filter by deck/status, card detail with rendered previews
- **Stats** — totals, deck breakdown, 7-day forecast, review history (Swift Charts)
- **Import** — file picker, share-sheet, sample decks, progress

## Features

| Area | Detail |
|------|--------|
| **Import** | `ApkgImporter.swift:36` — ZIPFoundation unzip, SQLite3 read of `collection.anki21`/`collection.anki2`, `media` JSON mapping, copy to `ApplicationSupport/AnkiMedia` |
| **Models** | `AnkiModels.swift:8` — `Deck`, `NoteType`, `Note`, `Card`, `ReviewLog` via SwiftData |
| **Scheduler** | `Scheduler.swift:22` — SM-2 variant matching Anki v2: new/learn/review/relearn handling, ease factors, lapse multipliers, interval formatting |
| **Templates** | `TemplateRenderer.swift:7` — `{{Field}}`, `{{FrontSide}}`, `{{#Field}}...{{/Field}}`, `{{^Field}}`, `{{text:Field}}`, `{{c1::cloze}}`, `[sound:]` → `<audio>`, CSS wrapping |
| **Rendering** | `WebView.swift:5` — `WKWebView` with `baseURL = AnkiMedia`, viewport meta, cloze & audio fixes |
| **Media** | Images `<img>`, audio `[sound:]` and `<audio autoplay>`, filename sanitization, bundled via `baseURL` |
| **Subdecks** | `::` hierarchy split into `displayName` / `parentPath` |
| **Persistence** | SwiftData, `AnkiCloneApp.swift:7` container, relationships `Deck ↔ Card ↔ Note` |

## Anki Compatibility

- Tested with exports from **Anki 2.1.66+** (`schedVer: 2`, `crt`, `dconf`, `models`, `decks`, `notes`, `cards`, `revlog`)
- Sample files: `samples/1212 Words.apkg` (1209 cards), `samples/540_MUST_KNOW_WORDS_FOR_TOEFL_IBT.apkg` — verified `collection.anki21` schema
- Preserves `due`, `ivl`, `factor`, `reps`, `lapses`, `dueDate` conversion (days since `crt` vs timestamp)
- Supports `.apkg` (single deck) and `.colpkg` (full collection) — same ZIP/SQLite layout
- Does **not** yet sync with AnkiWeb — manual file import only. FSRS parameters are mapped to SM-2 defaults; custom `dconf` per-deck config planned.

## Project Structure

```
AnkiClone/
  project.yml              — XcodeGen spec (iOS 17, ZIPFoundation)
  AnkiClone/
    AnkiCloneApp.swift
    Info.plist             — UTType for .apkg/.colpkg, file association
    Models/AnkiModels.swift
    Services/
      ApkgImporter.swift
      Scheduler.swift
      TemplateRenderer.swift
    Utils/WebView.swift
    Views/
      ContentView.swift    — TabView (Decks/Browse/Stats/Settings)
      DeckListView.swift
      StudyView.swift
      BrowseView.swift
      ImportView.swift     — DocumentPicker + share-sheet + samples
      StatsView.swift
      SettingsView.swift
    Resources/Assets.xcassets
  AnkiCloneTests/
```

## Build & Run

**Requirements:** Xcode 15.4+, iOS 17.0+

```bash
cd AnkiClone
# Generate (already generated; re-run after editing project.yml)
xcodegen generate
open AnkiClone.xcodeproj
# Select iPhone 15 Simulator, Cmd+R
```

CLI:

```bash
xcodebuild -project AnkiClone.xcodeproj -scheme AnkiClone -destination 'generic/platform=iOS Simulator' build
xcodebuild test -project AnkiClone.xcodeproj -scheme AnkiClone -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5'
# → BUILD SUCCEEDED, 3 tests passed
```

## Importing Decks

1. **From app:** Decks tab → `Import` → `Choose File` → select `.apkg`
2. **From Files/Share:** Long-press `.apkg` → Share → AnkiClone
3. **Simulator samples:** Import view auto-discovers `/samples/*.apkg` when run from repo path (dev only)

Media is extracted to `ApplicationSupport/AnkiMedia` and served to `WKWebView` via `baseURL`.

## Study Flow

`StudyView.swift:12` builds queue as:

```
learn (up to 20, sorted by due) → due (up to 200, dueDate ≤ now) → new (20, shuffled)
```

- `Again` → 1 min re-learn, re-queued 3 cards ahead (`left` encoding)
- `Hard/Good/Easy` → scheduler computes `interval`, `easeFactor`, `dueDate` via `Scheduler:58`
- Intervals shown on buttons via `nextIntervals(for:)` with `m/h/d/mo/y` formatting

## Known Limitations / Roadmap

- [ ] AnkiWeb sync (requires `sync` protocol)
- [ ] FSRS v4 exact replication (currently SM-2 with configurable `DeckConfig`)
- [ ] Image occlusion, LaTeX
- [ ] Add/edit notes, custom note types
- [ ] Export `.apkg`
- [ ] Background fetch for due notifications

## License

MIT — Anki® is a trademark of Damien Elmes. Not affiliated.

## How It Was Verified

- `xcodebuild build` → **BUILD SUCCEEDED**
- `xcodebuild test` → **3 tests passed** (`TemplateRenderer`, `Scheduler`)
- Manual SQLite inspection of `1212 Words.apkg` (1209 cards/notes) confirmed `decks/models/dconf` parsing
