# AnkiClone

An iOS app for studying Anki decks, built for **learning how words are pronounced**.

Import an `.apkg` or `.colpkg` file from Anki Desktop or AnkiWeb and study it on-device — no
account, no server, no network. SwiftUI + SwiftData + SQLite.

## The idea

Most vocabulary decks put a word, its meaning and its example sentences into one field, or into
several fields with no shared structure. Read aloud, that comes out as a single breathless blob:

> "ACCELERATE VERB Speed up expedite hasten quicken measures to accelerate the rate of economic
> growth The car accelerated smoothly away شتاب گرفتن"

AnkiClone parses a note into its parts first, then presents and speaks each part on its own:

| Part | Shown as | Spoken |
| ---- | -------- | ------ |
| Headword | Large, on its own | **Hear the word** — slower rate, its own voice |
| Phonetic respelling / IPA | Under the word | Never (it isn't a word) |
| Part of speech | A chip | Never |
| Meaning | A numbered "Meaning" section | With the answer |
| Examples | One row each | **Play all**, or tap any single sentence |
| Translation | Its own section, laid out RTL where appropriate | In *that* language's voice |
| Synonyms / opposites | Chips | Tap one to hear it |

Where a deck ships its own recording (`[sound:aberrant.mp3]`), that recording is played instead of
the synthesised voice.

## How the parsing works

`Services/CardContent.swift` classifies each field by name (`Word`, `Phonetic Spelling`, `Examples`,
`Persian`, …), then falls back to reading the markup for decks that only have `Front` / `Back`:

- list items and italics mark example sentences — the two conventions shared decks actually use;
- a bullet (`•`, `·`, or the `U+F0B7` Symbol-font bullet that Word exports leave behind) separates
  a gloss from the examples glued after it;
- `≠` marks an antonym; `:`-separated short phrases are a gloss list, not a sentence;
- an unmarked *first* chunk is always the definition, even when it repeats the headword.

Language is decided by script where the script is decisive (Japanese, Korean, Cyrillic, Greek,
Hebrew, Thai), and by field name where it isn't — a field called "Persian" settles a question the
Arabic alphabet cannot. Short Latin-script text is never guessed at; it falls back to the card
language set in Settings.

`Services/HTMLText.swift` is the scanner underneath: it splits field HTML into blocks at block-level
boundaries while keeping inline runs together, so a sentence broken up by `<a>` links survives as
one sentence rather than five fragments.

## Everything else

| Area | Detail |
| ---- | ------ |
| **Import** | `ApkgImporter.swift` — ZIPFoundation unzip, SQLite read of `collection.anki21`/`.anki2`, media copied to `ApplicationSupport/AnkiMedia` |
| **Scheduler** | `Scheduler.swift` — SM-2 as used by Anki v2: learning steps, lapses, ease factors, interval previews on every rating button |
| **Study** | Daily new/review limits, learn-ahead window, one-tap undo, suspend and bury, pinned rating buttons |
| **Templates** | `{{Field}}`, `{{FrontSide}}`, `{{#Field}}`/`{{^Field}}`, `{{text:}}`, `{{hint:}}`, `{{cloze:}}`, `[sound:]`; remote `<audio autoplay>` is defused so shared decks don't fire five players per card |
| **Rendering** | `WebView.swift` — self-sizing `WKWebView`; in dark mode, text that a deck hardcoded to black is lightened while keeping its hue |
| **Browse** | Search by field, tag or deck; filter by state; a card detail view with the parsed content and the rendered template side by side |
| **Stats** | Totals, per-deck breakdown, forecast, review history (Swift Charts) |

Cards the parser can't read as vocabulary — cloze deletions, image occlusion, anything with
`<img>` — fall through to the deck's own HTML template, unchanged. "Clean card layout" in Settings
turns the parsed view off entirely if you'd rather always see the deck as its author designed it.

## The icon

`Tools/make-icon.swift` draws it — a flashcard with a sound wave coming off it — straight into a
1024×1024 PNG with Core Graphics, so it can be regenerated or adjusted without a design tool:

```bash
swift Tools/make-icon.swift AnkiClone/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Build & run

Requires Xcode 15.4+ and iOS 17.

```bash
cd AnkiClone
./generate.sh                 # regenerate the Xcode project from project.yml
open AnkiClone.xcodeproj      # ⌘R
```

`generate.sh` wraps `xcodegen` because XcodeGen 2.45 emits `objectVersion = 77`, which Xcode 15.4
refuses to open; the script rewrites the header back to 60.

```bash
xcodebuild build -project AnkiClone.xcodeproj -scheme AnkiClone \
  -destination 'generic/platform=iOS Simulator'

xcodebuild test -project AnkiClone.xcodeproj -scheme AnkiClone \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Tests

52 unit tests and 2 UI tests, all passing.

The unit tests cover template rendering, the HTML scanner, the content analyzer, language
detection, the scheduler and due-date conversion, working from note fields copied verbatim out of
real decks.

A suite drives the importer over a real `.apkg` built on the fly, so the zip, the SQLite read and
the SwiftData write are exercised without shipping a deck inside the app: decks, notes and cards
land and are linked both ways, a collection nested inside a folder is still found, archive entries
resolve to the same destination whether or not the file exists yet (standardising a `/private` path
against one that is not there yet silently extracts nothing, and only on device), re-importing the
same package adds nothing and says so, progress is reported, and the two packages that cannot be read — a zstd collection and an archive with no collection at
all — surface as errors rather than a stalled spinner.

A dedicated suite covers what must never reach the synthesiser: tags, tags that only appear after
entity decoding (`&lt;div&gt;`, and the double-encoded `&amp;lt;div&amp;gt;` that scraper exports
produce), unterminated tags, `<script>` and `<style>` bodies, attribute values containing `>`,
`[sound:]` and cloze scaffolding, URLs, and the private-use glyphs Word-exported decks are full of.
A real inequality in a card — "5 < 6" — still has to survive, so a `<` only starts a tag when a
name follows it.

The UI tests drive the real app: opening the import sheet from the empty deck list, and reaching
the pronunciation settings. Studying is not covered end to end, because getting cards in now
requires picking a file from the system document picker.

## Importing your own decks

- **In the app:** Decks → `+` → Import deck…
- **From Files or another app:** share an `.apkg` to AnkiClone

Import runs off the main thread and reports progress as it goes; large decks stay cancellable.
Notes and cards are matched on their Anki id, so importing a package you already have adds nothing
and leaves your scheduling alone — the import screen says "Already Imported" rather than showing a
success screen full of zeroes.
Packages exported by Anki 2.1.50+ *without* "Support older Anki versions" store the collection as a
zstd blob, which this app cannot read — it says so rather than stalling, and the fix is to
re-export with that box checked.

Media is extracted to `ApplicationSupport/AnkiMedia` and served to the web view as its base URL.

## Not implemented

- AnkiWeb sync — import only
- FSRS (scheduling is SM-2 with Anki's defaults)
- Creating or editing notes, and exporting `.apkg`
- Image occlusion and LaTeX
- Per-deck configuration (`dconf` is read but daily limits are global)

## License

MIT. Anki® is a trademark of Damien Elmes; this project is not affiliated with or endorsed by Anki.
