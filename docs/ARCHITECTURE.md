# Architecture

This is a short tour of the code. The full design, including the reasoning behind each choice, is in [`SPEC.md`](../SPEC.md) (§6 architecture, §7 pipeline and algorithms, §8 saved data, §9 performance).

## Big picture

```
            ┌──────────────────────── one window per PDF ────────────────────────┐
            │ DocumentModel (@Observable, MainActor)                              │
            │                                                                    │
 PDF file ─▶│ Reader (PDFKit)  ◀── Sync ──▶  Rewrite panel        Chat overlay   │
            │      ▲                              ▲                    ▲         │
            └──────┼──────────────────────────────┼────────────────────┼─────────┘
                   │                              │                    │
         TextPipeline actor ──▶ blocks ──▶ AnalysisQueue actor     ChatSession
                   │                              │              (stream-json)
                   ▼                              ▼                    │
              Store actor  ◀──── results ──── BatchRunner ─── claude CLI ◀┘
      (atomic JSON, fingerprint,              (one-shot, JSON Schema)
       Markdown / Word export)
```

- **One `DocumentModel` per window**, `@Observable` and on the MainActor. Views read from it; long work happens in actors.
- **PDFKit stays on the MainActor** (`PDFDocument`/`PDFPage` are not `Sendable`). Text is extracted in small page batches and handed to actors as plain `Sendable` structs (lines, fonts, rectangles, text).
- **At most one analysis process and one chat process** run at any time across the whole app, sized for an 8 GB machine and a Pro-plan subscription. Other windows queue and say why they are waiting.

## Modules

| Folder | Responsibility |
|---|---|
| `App/` | `DocumentGroup(viewing:)` for PDFs (free Open, Recents, "Open With"), window layout with three resizable panes, menus and keyboard shortcuts, per-window `DocumentModel`. The document channel is read-only; writing marks into the PDF goes through a separate service with backup and atomic replace. |
| `Reader/` | `PDFView` wrapped for SwiftUI, per-page overlays for marks, hover and multi-selection, selection mini bar, zoom, thumbnails, search. |
| `TextPipeline/` | Line extraction with fonts and positions; cleaning (hyphenation, duplicated glyphs, spaced-out headers, headers/footers); heading, paragraph and exhibit detection; evaluation of the PDF's own outline; segmentation into blocks; manual table of contents. |
| `Claude/` | Locating the CLI, login check, `BatchRunner` for one-shot JSON calls, `ChatSession` for the long-lived streaming process, error and rate-limit mapping, loading prompts and schemas from `Resources/`. |
| `Analysis/` | Analysis queue, input building, response validation, matching Claude's quoted marks back to page text (`MarkMatcher`), glossary of terms, manual marks with undo, targeted regeneration, concept-map data. |
| `Rewrite/` | Right-hand panel: cards per block, rows rendered with TextKit 2 (`NSTextView`) so marks are drawn as custom attributes and hover can hit-test characters; in-place editing; export to Markdown, Word (`.docx` from the user's template), PDF and clipboard. |
| `Sync/` | Alignment model between PDF positions and rewrite rows; two-way scroll coordination without feedback loops; hover linking between PDF, rewrite and map. |
| `Map/` | Concept graph per chapter and for the whole book, layout, mini and expanded views. |
| `Chat/` | Floating panel, context building with a selectable scope (visible pages, section, chapter, whole PDF; beyond ~100k tokens the whole PDF is served through a read-only search mode), citation and marker parsing, summarisation when the context budget fills up. |
| `Store/` | Text fingerprint (so data survives rename/move), atomic JSON with backups, merge of concurrent writes, layout cache, Markdown export. |
| `Annotations/` | Free annotations in the style of macOS Preview: model, tools, rendering on the marks layer, hit testing, editing, undo/redo. |
| `Settings/` | Preferences, Claude status, and the **Summary Lab**: a window where the user rewrites the rewrite instructions in plain prose and A/B-tests them on a real block before saving. |
| `DesignSystem/` | Colour tokens, subject hue and mark shades, metrics, shared components. |

## Talking to Claude without an API key

The app drives the local Claude Code CLI with the user's subscription.

- **Analysis** (`BatchRunner`): `claude -p` with `--json-schema` and `--output-format json`, an isolated system prompt, no tools, no MCP and no session persistence. The structured answer arrives in `structured_output` and is validated before use. The prompts and schemas live in [`LelePdf/Resources/`](../LelePdf/Resources/), never inside the code.
- **Chat** (`ChatSession`): one persistent process with `--input-format stream-json --output-format stream-json --include-partial-messages`, so answers stream token by token (about 1 s to the first token when warm). `rate_limit_event`s become a banner in the UI.
- **Testing:** [`scripts/fake-claude/`](../scripts/fake-claude/) is a drop-in fake CLI that replays recorded scenarios (success, invalid JSON, timeout, not logged in, rate limit, streaming). The normal suite never calls Claude; real-call tests are opt-in with `LELEPDF_REAL_CLAUDE=1` and were run within a fixed budget (80 analysis calls, 25 chat calls) recorded in a measurements log.

## Saved data

Per PDF, in `~/Documents/LelePdf/<Title> [<fingerprint>]/`:

- `documento.json`: index, blocks, reading progress, subject colour
- `analisi.json`: rewrites, marks, links and terms (with a `.bak` copy)
- `annotazioni.json`: free annotations
- `riscrittura.md`: Markdown export for Obsidian

(File names are in Italian because they are part of the on-disk format of the app as it is used today.)

## Performance targets (MacBook Air M1, 8 GB)

- First page visible within 1 s (73-page report) and 2 s (600 pages).
- 60 fps scrolling with 500 visible marks; overlays drawn only for visible pages.
- App memory under 400 MB on a 600-page PDF, excluding the `claude` processes.
- Measured with a dedicated performance bench in [`LelePdfTests/PerfBench/`](../LelePdfTests/PerfBench/) and scripts in [`scripts/`](../scripts/).
