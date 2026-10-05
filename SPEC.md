# LelePdf · Specification v2.7

Date: 2026-09-14 · Author: Claude with the author · Status: v2.2 approved by the author on 2026-09-14; v2.3 (manual contents) and v2.4 (free annotations) requested by the author on 2026-09-15

## 0. How to use this document

- It is the source of truth for the autonomous development session. Whoever builds the app does not ask the author anything: when an ambiguity comes up, pick the option most consistent with this document, record it in the build decision log (kept private) and carry on.
- **[DECIDED]** marks a choice made by the author. **[TECHNICAL CHOICE]** marks a choice made by Claude, open to change if problems emerge (with a note).
- The reference design is `design/DirezioneA.dc.html` (preview: `design/DirezioneA-preview.html`, notes: `design/README.md`). Changes to the design are listed in §5.1.
- History: v1 was written after the 2026-09-14 spike and reviewed critically by a second agent. v2 fixes the issues that came out of that review: page-to-index mapping, chat flags, hand editing without calls, budget and replay, feedback source, usage limits, multiple windows, iCloud for data, PDFKit concurrency, hover on rewritten text, minimum widths, term register, read-only PDF, scroll measurement. v2.1 adds the selectable chat scope and context management when it fills up. v2.3 (2026-09-15, during the build) adds the manual contents levels T1-T4 (§5.3, §8, M7). v2.4 (2026-09-15) adds free Preview-style annotations (§5.13, §8, M7b). v2.5 (2026-09-16) adds the Summary Lab (§5.14, M10). v2.6 (2026-09-16) replaces the four mark colors with one color per subject in varying tones (§5.4). v2.7 (2026-09-19) reverses the PDF read-only rule: on an explicit command (or with the automatic option turned on in Settings, off by default) the 4 marks and the free annotations are written into the original file as standard PDF annotations, with a backup and an atomic write (§5.4, §5.13, §6.2 "App"). v2.2 adds build continuity (full context and usage limits, §10.5), the start and resume prompts (§10.6) and the OCR reminder (§14).

## 1. Goal

A personal macOS app for studying PDFs (books, reports and course case studies) with Claude used through the local CLI.

- On the left, a sidebar with Pages, Chapters and Concept maps.
- In the center, the original PDF with four kinds of marks, chosen by Claude or added by hand.
- On the right, a simplified and faithful rewrite, in the language of the PDF, linked to the PDF: the two sides scroll together and matching terms light up.
- A floating chat to ask questions about the PDF.
- Everything that is generated or edited stays saved and comes back when the document is reopened.

## 2. Constraints

- **The author's Mac:** MacBook Air M1, 8 GB of RAM, macOS 26.5, Xcode 26.6, Swift 6.3. Deployment target: macOS 26.0.
- **Claude only through the `claude` CLI** (v2.1.227 in `~/.local/bin/claude`) with the author's subscription. Currently Max, soon Pro: **everything is designed around the Pro limits** [DECIDED]. The numeric Pro limits are not published precisely: the restrictive rules (analysis on command, one process at a time, default effort) apply even if the plan is still Max during the build.
- **No App Sandbox:** it is required to launch the CLI. So no App Store, personal use only.
- **The PDF text is sent to Anthropic.** The interface must say so honestly.
- **The original PDF is never modified.**
- **Apple frameworks only in the app, no external dependencies** [TECHNICAL CHOICE]. Build tool: XcodeGen, installed with Homebrew [DECIDED: "whichever version you think best"].
- **The project folder lives on the Desktop, synced with iCloud.** Files may be "dataless", i.e. not yet downloaded: this happened on 2026-09-14 with `logo/E.png`. Build output and DerivedData must live outside the Desktop (the default DerivedData in `~/Library` is fine).

## 3. Out of scope for v1 (paused)

- Per-subject profiles, for example book/report versus case study [DECIDED].
- Actions menu: summary, flashcards, exam questions, free action [DECIDED].
- Snapshots and screenshots saved as images [DECIDED].
- Analysis of exhibits, tables and charts: they stay visible in the PDF, are not analyzed, do not enter the maps, and in the rewrite they only get a clickable cross-reference [DECIDED].
- Dark mode [DECIDED]. Colors are named tokens anyway, so adding it later is cheap.
- Obsidian canvas [DECIDED]: export is Markdown only.
- Context across several documents and a link to the second brain [DECIDED]: it will come from the author's second-brain project. Here there is only the Markdown export.
- Saving the chat [DECIDED].
- OCR of scanned PDFs [DECIDED: paused, to be remembered, §14]: for now a warning is shown.
- iPad/iOS, distribution, export of an annotated PDF, printing.

## 4. Facts already verified (2026-09-14, on the author's Mac)

| Topic | Measured result |
|---|---|
| CLI authentication | `claude auth status` → `loggedIn: true`, `subscriptionType: max` |
| Lean call | `claude -p … --model sonnet --safe-mode --tools "" --strict-mcp-config --no-session-persistence --system-prompt … --json-schema … --output-format json` works. The structured JSON arrives in the `structured_output` field (internally 2 turns, `stop_reason: tool_use`) |
| Isolation | With `--safe-mode` the author's global Claude Code instructions do not leak into the response (the author's name does not appear in the output) |
| Test block | Merck case, p. 3, 4,326 characters |
| Default effort | 25.9 s wall-clock (21.7 s internal), about 3.4k input tokens (all cache creation), 2,138 output. 12 marks out of 12 found exactly in the text; types: 6 rectangles, 4 circles, 2 underlines |
| `--effort low` | 15.7 s, 1,582 output tokens, 12 out of 12 found, but **no underline and no arrow**. So the default effort is used |
| Rewrite quality | With the test prompt the rewrite came out **longer than the original text** and the summary exceeded 2 sentences. The prompt must impose a length limit (§7.5) |
| Persistent chat | A single process with `--input-format stream-json --output-format stream-json --verbose --include-partial-messages` handles several questions. First token: 1.9 s cold, 1.1 s warm. Streaming arrives as `stream_event` events with `delta.type == "text_delta"`. `rate_limit_event` events exist. Verified input line: `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}` |
| Resources | A `claude` process uses about 380 MB of RAM; start-up 1-4 s |
| SwiftUI | `TextRenderer` and `TextAttribute` / `Text.customAttribute(_:)` exist (in SwiftUICore) and are used to draw the marks inside the right-panel text |
| APIs verified on the macOS 26.5 SDK | **PDFKit:** `PDFView.pageOverlayViewProvider` + the `PDFPageOverlayViewProvider` protocol (macOS 13+), the 4 overloads of `go(to:)`, `convert(_:to:/from:)` for points and rectangles, `visiblePages`, `currentPage`, `documentView` (`NSView`, scrolling is obtained via `documentView?.enclosingScrollView`), notifications `.PDFViewPageChanged` / `.PDFViewScaleChanged` / `.PDFViewVisiblePagesChanged`, `PDFDocument.findString(_:withOptions:)`, `outlineRoot`, `PDFOutline.insertChild(_:at:)`, `PDFPage.attributedString`, `selection(for: NSRange)`, `characterBounds(at:)`, `characterIndex(at:)`, `thumbnail(of:for:)`, `PDFSelection.selectionsByLine()`, `bounds(for:)`, `extendForLineBoundaries()`, `PDFThumbnailView`. **SwiftUI:** `onScrollGeometryChange(for:of:action:)`, `ScrollPosition` + `scrollPosition(_:anchor:)` (macOS 15+), `glassEffect(_:in:)` and `GlassEffectContainer` (macOS 26), `onContinuousHover`, `inspector(isPresented:)`, `windowToolbarStyle`, `ToolbarItemPlacement` `.principal` / `.navigation` / `.primaryAction` (not `.topBarLeading`/`.topBarTrailing`, which do not exist on macOS). **AppKit:** `NSView.boundsDidChangeNotification` + `postsBoundsChangedNotifications`, `NSTrackingArea` |
| Test PDF 1 | Draghi, *The future of European competitiveness* (Part A): 73 A4 pages, text present (missing only on p. 73), about 60k tokens. Built-in outline useless (2 entries: "EN_copyright page", "EN_file"). Headers with letter-spaced text ("T H E F U T U R E … — PA RT A \| C H A PT E R 2"), words hyphenated at line end ("connec- / tivity") |
| Test PDF 2 | HBS 9-707-509, *Strategy in the Twenty-First Century Pharmaceutical Industry: Merck & Co. and Pfizer Inc.*: 37 Letter pages, text present, about 31k tokens. No built-in outline. Licence line repeated on every page, footnote numbers glued to the text ("returns.20"), exhibits with tables that become unreadable text once extracted ("J&J J&J J&J…") |

Test PDF files (**read-only, never copy them into the repository**; they live in the author's private course folder):
- `Draghi M., The future of European competitiveness.pdf`
- `Strategy in the twenty-first century pharmaceutical industry Merck & Co. and Pfizer Inc.pdf`

## 5. User experience

### 5.1 Window (Direction A with changes)

Design proportions: titlebar 56 pt · sidebar 264 pt (collapsible) · PDF in the center · right panel 392 pt (resizable between 320 and 520 pt) · minimum window 1040×680.

The central PDF never goes below 440 pt: if space runs short, the right panel shrinks first, down to 320 pt, then the sidebar collapses automatically.

Changes with respect to the design [DECIDED unless noted]:
1. The subtitle "Subject profile · Law · 612 pages" becomes "612 pages".
2. The **Actions** menu and the **snapshot** button (camera) are removed.
3. All references to the double ⌥ are removed: the hint at the bottom of the right panel and the ⌥⌥ keys in the chat field.
4. The chat opens from a **round button with the logo**, in the **bottom-right corner of the window**.
5. The legend shows **the 4 marks** (§5.4) instead of the 4 color categories.
6. At the bottom of the sidebar, "Local analysis · no data sent" becomes "Text sent to Claude · results saved locally".
7. The pill in the middle of the titlebar shows the analysis (§5.5), not "Rewrite ch. 4 of 12".
8. The "Search in chapter" field stays, with a scope selector added (§5.10).

Shortcuts [TECHNICAL CHOICE]:
- ⌘O open · ⌘F search · ⌘J chat · ⌘↩ analyze the next block
- ⌘⇧1 sidebar · ⌘⇧2 right panel (moved from ⌘⌥1/⌘⌥2, which were freed for the T1-T4 headings) · ⌥⌘L "Follow the PDF" · ⌘⌥1…4 selection → T1-T4 heading (same multiple selection with ⌘)
- ⌘+ / ⌘− zoom · Esc closes the chat and the expanded map

### 5.2 Opening a PDF

- **Ways to open:** the Open panel (⌘O), dragging onto the window or onto the Dock icon, "Open with…" from Finder (the app registers as a Viewer for `com.adobe.pdf`, without becoming the default), File › Open Recent. One window per PDF.
- **Timing:** the first page appears immediately. In the background the fingerprint computation starts (§8); if the document is already known, marks, rewrite, maps and progress reappear within 1 s. At the same time extraction and block splitting (§7) start, beginning with the visible pages.
- **PDF without text** (fewer than 30 characters on more than 80% of the pages): banner "This PDF contains no selectable text: analysis is not available. You can add the text with an OCR program and reopen it". Reading still works.
- **iCloud file not yet downloaded:** opening goes through the document system, which coordinates the download; in the meantime "Downloading from iCloud…" is shown.

### 5.3 Sidebar: Pages / Chapters / Map

- **Pages:** thumbnails. A filled dot marks pages whose blocks are all analyzed, a half dot those analyzed only in part. Click to go to the page.
- **Chapters:** the contents tree.
  - If the built-in outline is "useful", it is used. It is useful if: it has at least 3 entries; at least 70% of the entries point to a valid page; the labels do not look like file names (`^EN_`, `.pdf`, "untitled", "file"); the entries cover more than 20% of the pages.
  - Otherwise the contents are generated (§7.4) and the label "Generated contents" appears.
  - "Regenerate contents" menu. The current section stays highlighted while scrolling.
  - **Manual contents** [DECIDED 2026-09-15, added in v2.3]: besides automatic generation, the user can select a heading in the PDF and add it to the contents by choosing level **T1, T2, T3 or T4** from the mini selection bar (§5.7). The entry takes the selected text (cleaned of line breaks and hyphenation dashes) and the page of the selection, and appears in the tree in document order with the right hierarchy: each level is indented more than the one above (T2 under the T1 that precedes it, and so on). From the tree, with an entry's context menu: "Change level" (T1-T4), "Rename", "Remove". Entries added or edited by hand are flagged as manual: "Regenerate contents" keeps them and replaces only the automatic ones. It works on top of a built-in outline, on top of a generated one, and with no outline at all.
- **Map:** "Chapter | Book" control [DECIDED].
  - The sidebar shows at most 12 nodes, plus a "+N nodes" node. "Expand" opens the large map over the PDF and the right panel, with zoom and pan; Esc closes it.
  - Nodes: rectangle (concept) and ellipse (who/how much), with the colors of the matching mark. Links: a plain line with a label (action) or an arrow with a label (effect).
  - Hovering a node lights up the matching marks in the PDF and in the rewrite. Clicking goes to the first occurrence on both sides.
  - Legend of the 4 marks and the text at the bottom as in §5.1.

### 5.4 The four marks [DECIDED]

| Mark | Meaning | In the PDF | In the rewrite | In the map | Color (token) |
|---|---|---|---|---|---|
| ▬ Filled rectangle | concept, what | rounded fill under the text, in multiply mode | colored background | rectangular node | blue: fill `#DBE7FF`, border `#9BB9F7`, chip text `#153E9E` |
| ◯ Empty circle | who or how much: actor, number, date | empty ellipse around the word | capsule outline | elliptical node | purple: stroke `#A57FE0`, chip text `#5B2C9B` |
| ___ Underline | action, decision | 2 pt line | underline | link with a label | green: `#57B894`, chip text `#0F5C42` |
| ___> Underline with arrow | consequence, effect | 2 pt line ending in an arrowhead | same | arrow with a label | amber: `#E39A3B`, chip text `#8A4A05` |

**Color per subject [DECIDED by the author 2026-09-16, v2.6, replaces the four colors of the table]:** the four marks already differ by shape, so they no longer have four different colors. Each document has a **subject color** chosen by the author (the author uses one color per subject) and all marks, map nodes and marked terms in the rewrite use **variations of the same color**:
- **Palette:** at least 8 hues (blue, green, purple, amber, red, teal, pink, graphite), each with a scale of 4-5 tones from lightest to darkest, readable on a white background and over the PDF text in multiply mode.
- **Tone assignment:** rectangle = light fill with a medium border; circle = medium-dark stroke; underline = medium stroke; arrow = dark stroke with a solid head. The states (repetition, linked, selected) stay as in §5.4, computed on the same hue.
- **Where it is chosen:** a "Subject color" selector in the sidebar legend (it applies to the open document and is saved in `documento.json` as `colorTheme`) and a default color for new documents in Settings. Changing it immediately updates the PDF, the rewrite and the map.
- **Free annotations (§5.13) keep their own colors**, chosen as in Preview.

States of each mark:
- **Normal.**
- **Repetition:** the same term further on in the text, at 40% opacity.
- **Linked (hover):** livelier tone, i.e. higher saturation, stroke +1 pt and a more intense fill. It shows on the matching mark on the other side [DECIDED].
- **Selected.**

In the PDF the marks are drawn over the page, in memory, as in the earlier versions of this specification. **[DECIDED by the author 2026-09-19, v2.7]** On the explicit command "Save the marks in the PDF" (File menu, ⌘S) or with the automatic option turned on in Settings (off by default), the marks are also written into the original file as standard PDF annotations, so that Preview shows them, with a `<name>.lelepdf-backup.pdf` backup on the first write and an atomic replacement. Details in §5.13.

### 5.5 Analysis on command [DECIDED]

- **Unit: the block**, i.e. a subsection or a group of paragraphs chosen by length (§7.3).
- **Commands:**
  - **"Analyze the next block"** button at the bottom of the right-panel content (and ⌘↩). It analyzes the first unanalyzed block after the one at the reading position; if there are none further on, the first unanalyzed one from the start.
  - Hovering a PDF paragraph shows a small **"Analyze from here"** pill next to the margin, which analyzes that paragraph's block.
  - Pressing again during an analysis queues the block (at most 5, in order, cancellable).
- **During the analysis:**
  - In the right panel, in place of the block, a placeholder card with "Claude is analyzing 3.2" and the estimated time (moving average of the latest analyses). An X cancels it.
  - Titlebar: spinner, "Analysis 3.2 · 12 of 58 blocks" and a progress bar equal to analyzed blocks over total blocks.
- **Result:** the marks fade in on the PDF, the card fills in, the map updates, progress is saved immediately.
- **Analyzed blocks:** a thin vertical bar (2 pt, accent at 40%) in the left margin of the PDF, next to their lines.
- **Errors:** shown in the card, with "Retry".
  - CLI not found; user not logged in.
  - Usage limit reached, with the reset time if known.
  - No network; no response within 120 s.
  - Invalid response: one automatic retry, then an error.
- **On reopening:** "Resume from 3.3", i.e. the next unanalyzed block after the last analyzed one.

### 5.6 Rewrite (right panel) [DECIDED]

- **Header:** "Simplified rewrite", path Ch. › current section, **"Follow the PDF"** switch (on by default).
- **Content, in document order:**
  - Chapter and section headings.
  - A card for every analyzed block. A compact placeholder for every unanalyzed block ("Not analyzed yet · p. 12 · Analyze").
  - For every exhibit a cross-reference row ("Exhibit 5 · p. 19 ↗") that leads to the place in the PDF.
- **Block card:** title and page chip (click → the PDF goes to the start of the block), then the elements:
  - `summary`: at most 2 sentences, always first
  - `definition`: box with the label "DEFINITION"
  - `bullets`: bullet list; the arrow → indicates cause-effect
  - `steps`: numbered sequence or timeline
  - `table`: mini table, at most 4 columns and 8 rows
  - `callout`: callout with a colored left border
  - `paragraph`: paragraph
- **Graphical marks:** those listed above [DECIDED, "with graphical marks"].
- **Marked terms in the rewritten text:** they have the same mark style as in the PDF (drawn by the text view described in §6.2) and are linked to the matching mark in the PDF.
- **Card "…" menu:**
  - "Shorter", "More Detailed", "Rewrite Like This…" (field for the instruction): Claude regenerates only that block.
  - "Edit Text": edit by hand directly in the card. Marked terms stay attributes of the text: if you rewrite them the mark follows, if you delete them the mark disappears. On save, **no call to Claude is made**: the text is converted locally into the format with `{{mX|…}}` markers and the marks are rebuilt from it.
  - "Restore Claude's Version", visible if the card has been edited.
- **Protection of edits:** cards edited by hand carry the label "edited" and are never overwritten without confirmation.
- **Bottom margin of 72 pt**, so that the chat button does not cover "Analyze the next block".

### 5.7 Hand-placed marks [DECIDED]

- **Adding:** select text in the PDF and a mini bar with the 4 marks appears.
- **Changing or removing:** click an existing mark and the same bar appears with "Change" and "Remove".
- **Claude's marks that are removed:** they are hidden, not deleted, and they also disappear from the map.
- **Manual rectangles and circles** become nodes of the chapter map and of the book map.
- **Manual underlines and arrows** become links if, in the same sentence, there is a node before and one after; otherwise they stay only in the PDF.
- **Rewrite:** if the term marked by hand appears in the rewrite of the block (case-insensitively), it is marked there too.
- **Saving:** everything is saved immediately.

### 5.8 DeepL-style linked scrolling [DECIDED]

- **Alignment model:** an ordered sequence of segments (chapter headings, section headings, blocks, exhibit cross-references). Each segment has a vertical range in the PDF (continuous document coordinates) and one in the right-panel content.
- **Reading line:** at 30% of the visible height, on both sides.
- **When the user scrolls one side** (A):
  - find the segment *i* that contains the reading line in A and the fraction *f* travelled inside the segment;
  - the other side (B) moves to `start_B(i) + f × height_B(i) − position of the reading line in B`, on every frame and without animation;
  - a programmatic scroll does not re-trigger the synchronization (no bouncing).
- **Only with "Follow the PDF" on.** Both sides can lead.
- **Unanalyzed blocks:** the placeholders guarantee every block a minimum height of 44 pt on the right.
- **Linking terms:**
  - Hovering a mark in the PDF: the mark with the same id in the rewrite lights up; for a repetition, the mark of the term in its first block.
  - Hovering a term in the rewrite: the matching marks in the PDF light up.
  - If the counterpart is not visible, hover does not scroll anything; a click brings the other side to it.
- **Criteria:** at 60 fps, with scrolling on both sides, the start of the matching block stays within ±40 pt of the reading line; the highlight appears in under 50 ms.
- **How it is measured:** in a Debug build with the environment variable `LELEPDF_MEASURE=1` the coordinator records, for every scroll frame, the offset in pt between the two sides and the frame duration, plus the time between hover and highlight. A UI test scrolls the two PDFs automatically and writes minimum, median and 95th percentile to the measurements log. The criterion passes if the 95th percentile meets the thresholds.

### 5.9 Floating chat [DECIDED]

- **Button:** round, 44 pt, with the logo, 16 pt from the bottom-right corner of the window. Tooltip "Ask the PDF", shortcut ⌘J.
- **Panel:** 680 pt wide, centered at the bottom over the content, with a light dark veil as in the design.
  - Context pill ("Context: Ch. 4 · pp. 42–43 · visible text").
  - Scrolling conversation, with streamed answers.
  - Clickable page chips (the PDF goes to the page and the right panel follows).
  - Dashed "not in the PDF" chip for pieces of external knowledge.
  - "Go to the point", which leads to the first citation.
  - Input field with the **scope selector** [DECIDED]: Visible pages · Section · Chapter (default) · Whole PDF. Next to each option the estimated size (for example "≈ 12k tokens"), so it is clear how much it weighs on the limit (§7.8.1).
  - **Context indicator:** a small ring showing how full the conversation context is, plus the "New conversation" button (§7.8.2).
- **Language:** the one the user writes in.
- **Saving:** none. The conversation stays while the window is open and disappears when it is closed.
- **Closing:** Esc or another click on the button.

### 5.10 Search [DECIDED]

- **"Search in chapter" field** with scope "Chapter | Whole PDF".
- **Results** highlighted with the system search style and a counter "3 of 12". ↩ goes to the next one, ⇧↩ to the previous one.
- **Scope:** the current chapter is delimited by the contents; with no contents the search covers the whole PDF.
- **Known limit:** search uses `PDFDocument.findString` on the raw page text, so a word hyphenated at line end may not be found. In v1 that is acceptable.

### 5.11 Settings

- **Data folder:** by default `~/Documents/LelePdf`, changeable, for example to put it inside the second brain.
- **Path of the `claude` CLI:** detected automatically (`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `zsh -lc 'command -v claude'`), with the option to set it by hand.
- **Models:** analysis and chat each have a Sonnet (default) / Opus selector.
- **Claude status:** "Connected as …" or "Not connected", with the instructions (`claude auth login` in Terminal) and a "Check" button.

### 5.12 Empty and error states

- **First launch:** "Open a PDF" and a check of the CLI status.
- **CLI missing or not logged in:** banner in the right panel with the instructions. Reading, manual marks and saved data work anyway.
- **Usage limit reached:** banner with the reset time, if known. The analysis commands stay clickable but, while the limit is active, immediately show the same message; "Retry" in the banner forces a new attempt anyway.
- **PDF without text:** see §5.2.

### 5.13 Free Preview-style annotations [DECIDED by the author 2026-09-15, v2.4; details TECHNICAL CHOICE]

Annotation tools like those in Apple's Preview, **separate from the 4 marks**: they do not enter the map, the glossary, the term register or the calls to Claude. The PDF is not modified automatically: annotations are drawn over the page and saved in the app's data, and until the explicit save command of v2.7 arrives (or the automatic option, off by default) the file on disk stays byte-for-byte the one that was opened.

**[DECIDED by the author 2026-09-19, v2.7]** With "Save the marks in the PDF" (or the automatic option), these annotations are also written into the original PDF as native annotations (highlight, underline, strikethrough, pen, shapes, text box, note), with the same backup and the same atomic write as the 4 marks. Annotations created in Preview on the same file are read on reopening and shown in LelePdf without duplicates; those written by LelePdf are recognized by a signature (`userName`, `/NM`) and are not re-imported as if they were new.

- **Fidelity to Preview [DECIDED by the author: "I want them to be like Apple's Preview"]:** look and behavior must be those of Preview on macOS 26 on the author's Mac, not a reinterpretation. Concretely:
  - **Native rendering:** annotations are drawn with PDFKit's native annotations (`PDFAnnotation`: highlight, underline, strikeOut, ink, square, circle, line with arrows, freeText, text/note with popup), the same engine as Preview, created **only in memory** on the open `PDFDocument` and recreated from `annotazioni.json` at every opening. The PDF file is never written (`fileWrapper` always returns the original bytes, hash test).
  - **Identical markup toolbar:** same order of the tools, same icons (equivalent SF Symbols) and same labels as Preview, taken from the localization files of `/System/Applications/Preview.app` (for example "Show Markup Toolbar" / "Hide Markup Toolbar", "Highlight", "Underline", "Strikethrough", the shape tools, shape attributes, fill color, note tool, "Add Note").
  - **Same menus and behaviors:** Highlight button with a drop-down menu of colors plus Underline and Strikethrough; shapes menu; shape style popover (thickness and dash), border color, fill color, text style (font, size, color, alignment); text box that is born with the word "Text" selected; yellow sticky note with a popover; selection and drag handles as in Preview; "drag-to-highlight" while the Highlight tool is active (drag over the text and it stays highlighted); default colors and transparencies equal to Preview's.
  - **Mandatory comparison:** the developer opens the same PDF in Preview and in LelePdf, makes the same annotations and compares the screenshots (Preview is authorized in computer-use). If computer-use is not available, the comparison is handed to the author in the final phase.
  - **Excluded:** signature, crop, rotation, color adjustment, loupe and mask of Preview (not needed for studying; the signature touches credentials).
- **Markup toolbar:** a "Markup" button (pen-tip icon, as in Preview) in the toolbar and the shortcut ⇧⌘A (as in Preview). It opens the toolbar with the tools under the toolbar; when closed, the PDF goes back to normal reading and the annotations stay visible.
- **Tools on text** (select the text, then choose; they also appear in the mini selection bar of §5.7, after the 4 marks and T1-T4):
  - **Highlight** with Preview's colors (yellow by default, green, blue, pink, purple), with the same look as Preview;
  - **Underline** and **strikethrough**, in the chosen color.
- **Free tools on the page:**
  - **Pen**, freehand, 3 thicknesses, smoothed stroke;
  - **Shapes** (menu as in Preview): line, arrow, rectangle, rounded rectangle, oval, speech bubble, star, polygon (stroke, fill and color chosen; with ⇧ proportions are constrained);
  - **Text box:** click on the page, type directly; simple font, size and color;
  - **Note:** a sticky-note icon on the page, which opens a popover with the text of the note, as in Preview.
- **Editing:** Selection tool to pick an annotation, move it, resize it (handles), change its color, delete it (⌫). **Eraser** to delete pen strokes by touching them. **Undo/Redo** (⌘Z, ⇧⌘Z) for all annotation operations of the window.
- **Colors and thicknesses:** the last one used for each tool is remembered.
- **Coordinates:** in page space (PDF points), so they follow zoom and scrolling; an annotation belongs to a single page.
- **Saving:** immediately, in `annotazioni.json` (§8). Reopening: they reappear with the other data within 1 s.
- **Export:** in `riscrittura.md`, for each page with annotations, a section at the end of the chapter "Annotations · p. 12" with the highlighted texts (`==text==` with the color in brackets), the text boxes and the notes (`> [!note] p. 12`). Drawings and shapes are not exported.
- **Performance:** drawing only on the visible pages, same layer as the marks (§9).
- **Pages sidebar:** a small pen icon on the thumbnails of pages with annotations.

### 5.14 Summary Lab [DECIDED by the author 2026-09-16, v2.5]

The author does not program, but wants to be able to change on their own how Claude rewrites blocks and see the effect immediately.

- **Where:** a "Summary Lab" window (Window menu, or from Settings).
- **On the left:** the text of the instructions for Claude (the content of `Prompts/analysis.md`), editable, with "Restore the original instructions".
- **On the right:** the choice of a block of the open PDF and two columns, "Current version" and "New trial", with the **Try** button (a real call to Claude, counted) and the word count of the block and of each rewrite.
- **Saving:** "Save as default" writes the customized instructions into the data folder (`istruzioni-riscrittura.md`), which from then on are used in place of the built-in ones; "Restore" goes back to the built-in ones. Rewrites already made do not change.
- **Warning:** every Try uses one call of the subscription, like a normal analysis.

## 6. Architecture

### 6.1 Repository structure

```
LelePdf/
  SPEC.md                    this document
  project.yml                XcodeGen; LelePdf.xcodeproj is generated and ignored by git
  LelePdf/                   app sources
    App/  DesignSystem/  Reader/  TextPipeline/  Claude/  Analysis/
    Rewrite/  Map/  Sync/  Chat/  Store/  Settings/
    Resources/Prompts/       analysis.md, rewrite-block.md, toc.md, chat.md
    Resources/Schemas/       analysis.schema.json, toc.schema.json
    Assets.xcassets/         AppIcon, chat button logo, accent colors
  LelePdfTests/              unit and integration tests
  scripts/                   build.sh, test.sh, run.sh, make-icons.sh, fake-claude/
  design/  logo/             already present
```

The author's private working notes (status, use cases, feedback, build decisions, measurements, final report) are kept outside the public repository.

### 6.2 Modules

| Module | Responsibility |
|---|---|
| App | `DocumentGroup(viewing:)` for PDFs [TECHNICAL CHOICE: Open, Recents, "Open with" and iCloud coordination for free], window, commands, shortcuts. The `DocumentGroup` channel stays read-only: `fileWrapper(configuration:)` always returns the original file unchanged, and a test checks that the hash of the PDF on disk does not change through that channel. Since v2.7 there is a save command, but it does not go through there: "Save the marks in the PDF" (File menu, ⌘S) calls `PDFAnnotationWriteService`, which writes the backup and the atomic replacement outside the `FileDocument` life cycle (§5.4, §5.13) |
| DesignSystem | Color tokens (accents in the asset catalog; hue and tones of the marks computed), `MarkStyle`, typography, shared components (page chip, card, pill) |
| Reader | `PDFView` in `NSViewRepresentable`; per-page mark overlay; mini selection bar; thumbnails; "Page · Zoom" bar; search |
| TextPipeline | Extraction of lines with fonts and positions, cleaning, headings, paragraphs, exhibits, blocks, evaluation of the built-in outline, candidates for the generated contents |
| Claude | CLI lookup, login check, `BatchRunner` (one-shot processes with JSON), `ChatSession` (persistent stream-json process), loading of prompts and schemas, mapping of errors and limits |
| Analysis | Analysis queue, input construction, validation, matching of marks to text, term register, contents generation |
| Rewrite | Right panel, cards, targeted regeneration. The text of the cards is an `NSTextView` with TextKit 2 wrapped in SwiftUI [TECHNICAL CHOICE]: it draws the 4 marks as custom attributes, gives the index of the character under the mouse for hover and allows in-place editing. If TextKit causes sizing problems, the alternative is SwiftUI's `Text` + `TextRenderer`, with the term rectangles computed separately for hover |
| Map | Concept graph, chapter and book map, node layout, mini and expanded views |
| Sync | Alignment model, scroll coordination, hover linking between the two sides and the map |
| Chat | Button, panel, context construction, parser for citations and markers, process life cycle |
| Store | Fingerprint, atomic JSON reading and writing, fingerprint index, Markdown export, regenerable cache |
| Settings | Preferences (§5.11) |
| Annotations | (v2.4) Free Preview-style annotations (§5.13): model, tools, drawing on the marks layer, selection and editing, undo/redo, saving to `annotazioni.json` |

### 6.3 Concurrency and state

- **Language:** Swift 6 with full concurrency checking.
- **Per-window state:** one `@Observable` `DocumentModel` on the MainActor.
- **Dedicated actors** for `TextPipeline`, `Store` and `AnalysisQueue`.
- **`claude` processes:** at most 1 analysis process and 1 chat process active at the same time across the whole app [TECHNICAL CHOICE: 8 GB of RAM and Pro limits].
- **Multiple windows:** the limit is global. If a window requests an analysis while another is running, the block stays in its window's queue with "Waiting: another window is analyzing" and starts as soon as the process is free. The chat process belongs to the window in which the chat is open: opening the chat in another window closes the previous process, but its conversation stays visible.
- **PDFKit and concurrency:** `PDFDocument` and `PDFPage` are not `Sendable`. PDFKit access stays on the MainActor (`@preconcurrency import PDFKit`), in small batches of pages so as not to block the interface; actors receive and return only `Sendable` structs that have already been extracted (lines, fonts, rectangles, text).

## 7. Pipeline and algorithms

### 7.1 Extraction

- **Lines:** for each page, `PDFPage.attributedString` plus character positions (`characterBounds(at:)`) to rebuild the lines (text, rectangle, font size, bold, baseline).
- **Work order:** visible pages first, then the others at low priority.
- **Regenerable cache** in `~/Library/Caches/LelePdf/<fingerprint>/layout.json`.

### 7.2 Cleaning

The correspondence between clean text and the original character indices of the page is always kept, because the marks have to be mapped back onto the PDF.

1. **Headers and footers:** lines in the top or bottom 8% of the page whose normalized text (without spaces and digits) repeats on at least 30% of the pages are removed. It covers the Draghi header, the license line of the Merck case and page numbers.
2. **Letter-spaced text:** sequences of single-letter tokens are recompacted into words.
3. **Hyphenated words:** `word-⏎word` is joined when the next line starts in lowercase.
4. **Footnote numbers:** superscript digits (smaller font, raised baseline) are removed from the text sent to Claude, keeping the positions.
5. **Ligatures:** ﬁ → fi, ﬂ → fl.

### 7.3 Headings, paragraphs, exhibits and blocks

- **Headings:** lines with a font at least 1.15 times the body text, or short bold lines (fewer than 12 words) followed by normal text, or numbering ("4.1", "Chapter 2"). The level comes from the ranking of the sizes.
- **Paragraphs:** separated by a vertical gap larger than 0.6 times the line spacing or by a first-line indent. A paragraph continues onto the next page if the last line does not end in final punctuation and the next page starts in lowercase.
- **Exhibits, tables and figures:** zones that begin with a caption ("Exhibit N", "Figure N", "Table N", "Source:") or lines dense with short tokens (more than 40% numeric or many repetitions). They are excluded from the blocks and produce an `ExhibitRef(label, page)`.
- **Block rule** [DECIDED: paragraph or subsection depending on length]:
  - a subsection of up to 700 words is a single block;
  - a longer subsection is split into groups of consecutive paragraphs of 250 to 600 words;
  - a single paragraph over 700 words is a block on its own;
  - a block never crosses a section boundary and never cuts a paragraph.
- **Fallback:** if in a stretch no reliable headings or paragraphs are found, the blocks are groups of lines of about 400 words that end at a sentence end.
- **Stable block id:** hash of the section path, the first 60 characters of the clean text and the starting page. If the splitting algorithm changes, saved analyses are re-attached through the text hash; those that cannot be re-attached are flagged as "orphaned" and shown at their page.
- **Index map of a block:** the clean text of a block is the concatenation of stretches from different pages. For each block the table `[(page, cleanStart, cleanLength, charMap)]` is cached, where `charMap` associates each clean character with the index of the original character in its page (added spaces and joins of hyphenated words point to the nearest original character). A range found in the block text is thus resolved into one or more (page, character range in the page) pairs and then into `PDFPage.selection(for:)`; a mark straddling two pages produces two selections. Dedicated tests: a block straddling a page and, for 3 pages of each PDF, `page.selection(for: range).string` equal to the same range of `page.string`.

### 7.4 Generated contents

1. The candidates are the headings found in §7.3 plus the chapter names derived from repeated headers (for example "CHAPTER 2" in the Draghi report), read before the headers are removed.
2. Claude (Sonnet model, schema `toc.schema.json` = `{entries:[{title, level (1-3), page}]}`; level 4 exists only for manual entries, §5.3) cleans up the candidates: it removes false positives, fixes the levels, corrects split headings. It receives only the candidates with their page and the 20 words that follow them, not the whole document.
3. The contents are saved in `documento.json`; the PDF is not touched.

### 7.5 Analysing a block

**Input** (user message):
- document title;
- section path;
- summary of the previous block, if analyzed;
- glossary of the terms that already exist (up to 60, the most recent and frequent: `termId`, term, mark type);
- clean text of the block, with the cited exhibits replaced by `[Exhibit 5, p. 19]`.

**Call:** `claude -p <input> --model sonnet --safe-mode --tools "" --strict-mcp-config --no-session-persistence --system-prompt <Prompts/analysis.md> --json-schema <Schemas/analysis.schema.json> --output-format json`, with default effort (§4). Working directory: `~/Library/Caches/LelePdf/cli/`, empty. Timeout of 120 s; cancellation with terminate and then kill after 2 s.

**Output schema** (`analysis.schema.json`):
```
{
  title: string,
  rewrite: [ { kind: summary|definition|bullets|steps|table|callout|paragraph,
               text?: string, items?: [string], columns?: [string], rows?: [[string]] } ],
  marks:   [ { id: "m1", text: <copied exactly from the block>, mark: rectangle|circle|underline|arrow,
               term: <canonical form>, termId?: <existing id from the glossary, if it is the same concept> } ],
  links:   [ { from: <markId or termId>, to: <markId or termId>, via?: <markId of an underline or arrow>,
               label: string, kind: action|effect } ]
}
```
In the rewrite text, marked terms are written `{{m3|shown words}}`.

**Prompt v1:** it starts from the one verified on 2026-09-14 (during the spike, together with the schema and the spike scripts), adding these rules:
- rewrite in the language of the block, faithful, with no new facts, understandable on its own;
- **total length of the rewrite at most 60% of the words of the block**; the `summary` has at most 2 sentences;
- at most 12 marks, of 1-5 words, copied exactly from the text; use all 4 types when the text contains actions or effects;
- reuse the glossary `termId` when the concept is the same;
- ignore headers, page numbers and license lines;
- do not analyze exhibits: just cite them.

**Post-processing:**
1. Schema validation. If it fails, one retry; then an error.
   Term register: if the `term` of a mark matches (case-insensitively and with normalized whitespace) a term of the glossary, the existing `termId` is used whatever Claude proposed; otherwise a new `termId` is created.
2. Matching of each mark: exact search in the clean text of the block (the occurrence after the one of the same text already matched), then case-insensitive, then with tolerance (Levenshtein distance ≤ 2 on equivalent tokens). Unmatched marks are discarded and recorded in the log.
3. Conversion of the clean indices into page character ranges, then into `PDFSelection`, then into one rectangle per line of the overlay.
4. **Repetitions:** computed on load, not saved. They are the later occurrences of the same term in the analyzed blocks, excluding the real marks.
5. `{{mX|…}}` markers with an unknown id: the braces are removed and the text stays.

**Quality targets**, measured on the test PDFs and recorded in the measurements log:
- at least 95% of the marks matched;
- all 4 types present in the 8 test blocks;
- average length of the rewrite no more than 70% of the original;
- no invented facts on a spot check of 5 blocks.

### 7.6 Targeted regeneration

"Shorter", "More Detailed" and "Rewrite Like This…" use the same schema. The input also contains the current rewrite and the instruction. Manual marks stay; Claude's marks of the block are replaced by the new ones. The term register rule (§7.5) applies, so that the map does not fragment.

### 7.7 Maps

- **Nodes:** terms with rectangle or circle marks, one per `termId`. **Links:** from the `links` and from manual marks (§5.7).
- **Chapter map:** the nodes and links of the blocks of the chapter.
- **Book map:** the union of everything. The weight of a node is its number of occurrences; the top 40 by weight are shown, plus those with links between different chapters, grouped by chapter with a group background.
- **Layout** deterministic, always identical for the same data:
  - central node = the one with the most links;
  - levels computed by distance from the central node;
  - inside each level, ordering by barycenter to reduce crossings;
  - overlap resolution.
- **Criterion:** no overlap between nodes, verified by a test on the layout function.

### 7.8 Chat context

- **System prompt** (`Prompts/chat.md`):
  - document title, contents with pages, and glossary;
  - clean text of the chosen scope (§7.8.1);
  - citation rules: `[p. 42]` for citations and `<fuori>…</fuori>` around the parts that do not come from the PDF (`fuori` means "outside").
- **Command:** `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model <sonnet|opus> --safe-mode --tools "" --strict-mcp-config --no-session-persistence --system-prompt <built prompt>`, working directory `~/Library/Caches/LelePdf/cli/`. Format of the input lines as in §4.
- **Each user message** is preceded by the range of visible pages.
- **Life cycle of the persistent process** (`stream-json`):
  - it starts on the first opening of the chat in the window;
  - if the scope changes, for example when moving to another chapter, the next question restarts the process with the new context, and the note "Context changed: Ch. 5" appears in the conversation;
  - it closes after 10 minutes of inactivity or when the window is closed.
- **Streaming parser:** turns `[p. N]` into chips and `<fuori>` into a dashed chip, even when the marker arrives split between one event and the next.
- **`rate_limit_event` events:** they are read and show a warning when the limit is approaching or reached. Their format is not documented: the parser records the raw event in the log and, if it does not recognize the fields, shows a generic warning.

### 7.8.1 Chat scopes [DECIDED: selectable scope]

| Scope | What Claude receives |
|---|---|
| Visible pages | Clean text of the visible pages, plus one page before and one after |
| Section | Clean text of the current section |
| Chapter (default) | Clean text of the current chapter |
| Whole PDF | Up to 100k tokens: the entire clean text. Beyond that: contents, glossary and summaries of the analyzed blocks, plus text search with read-only tools (search mode, below) |

- If a scope exceeds 100k tokens, for example an enormous chapter, search mode is used.
- **Search mode:** the clean text of the document is written page by page to `~/Library/Caches/LelePdf/<fingerprint>/pagine/p-0042.txt`. The chat process starts with that working directory and with `--tools "Read,Grep,Glob" --allowedTools "Read(./**)" "Grep(./**)" "Glob(./**)" --permission-mode dontAsk` in place of `--tools ""`.
- **Mandatory safety criterion in M9:** a test asks Claude to read a file outside that folder (for example `~/.zshrc`) and checks that the read is denied. If the test does not pass, search mode is disabled and "Whole PDF" stays available only below 100k tokens, with a clear message.
- **Changing scope** restarts the process with the new context and carries the conversation summary with it (§7.8.2), so that the thread is not lost.

### 7.8.2 When the context fills up [TECHNICAL CHOICE]

- **Measurement:** on every answer the `result` event reports the tokens used (input, cache created, cache read). The app computes how much the conversation weighs against a **budget of 80k tokens**, adjustable in Settings. The budget is deliberately far below the maximum window: with Pro every question rereads the whole context and consumes the limit.
- **Ring in the chat panel:** green up to 60%, orange from 60%, red from 85%.
- **From 60%** "The conversation is long · Summarize and continue" appears. **From 85%** the summary starts by itself before the next question, with a note, so that an answer is never cut off halfway.
- **Summarize and continue:** a short call asks Claude for a compact summary of the conversation (questions, key answers, cited pages; at most 600 words). The process restarts with the same scope plus the summary as memory. In the window the conversation stays fully visible, with a "Conversation summarized" divider.
- **New conversation:** clears everything and restarts from zero with the current scope.
- **No automatic compaction by the CLI:** it is not relied on, because it might also summarize the PDF text.

## 8. Saved data [DECIDED]

**Location:** `<data folder>/<PDF title> [<first 8 digits of the fingerprint>]/`

- **`documento.json`**, `version: 1`:
  - `fingerprint`, `fileName`, `lastKnownPath`, `pageCount`, `title`;
  - `toc {source: native|generated, entries[{id,title,level,page, origin?: auto|manual, pageY?}]}`: `level` from 1 to 4; `origin` is absent or `auto` for native or generated entries, `manual` for those added or edited by hand (§5.3); `pageY` is the vertical position of the selection in the page, used to order several headings on the same page;
  - `segmentationVersion`, `blocks[{id, sectionPath, pageStart, pageEnd, textHash, words}]`, `exhibits[{label,page}]`;
  - `progress {analyzedBlockIds[], lastReadPage, lastAnalyzedBlockId}`, `updatedAt`.
- **`analisi.json`**, `version: 1`:
  - `blocks{<blockId>: {status, analyzedAt, model, title, rewrite[], rewriteEdited, claudeRewrite[], marks[{id, termId, type, text, source: claude|manual, page, range{start,length}, hidden}], links[{id, from, to, label, kind, source}]}}`;
  - `terms{<termId>: {term, type, firstBlockId}}`.
- **`riscrittura.md`:** export for Obsidian, regenerated 2 s after every change. It is never read back: the source of truth is the JSON files.
  - YAML frontmatter: `title`, `source`, `pages`, `fingerprint`, `updated`, `tags: [lelepdf]`.
  - Structure: `# Title`, `## Chapter`, `### Section`, `#### Block title · p. 42`.
  - Elements: `summary` and `paragraph` as paragraphs; `definition` as `> **Definition:** …`; `bullets` as `- …`; `steps` as `1. …`; `table` as a Markdown table; `callout` as `> [!note]`; exhibits as `*Exhibit 5, p. 19*`.
  - Marks [TECHNICAL CHOICE, to be revisited when the second brain is connected]: rectangle `==term==`, circle `**term**`, underline `<u>term</u>`, arrow `<u>term</u> →`.
  - After every block, a hidden Obsidian comment with the marks in a machine-readable form, for example `%% lelepdf: {"block":"b12","marks":[{"termId":"t3","term":"R&D spending","type":"rectangle"}]} %%`. This way a future connection to the second brain does not have to guess the types from the formatting.
- **Fingerprint index:** `<data folder>/.indice.json`, with fingerprint → folder and SHA-256 of the file bytes → fingerprint (fast path).
- **Document fingerprint:** SHA-256 of the page count plus the text of all pages. It survives renaming, moving and metadata-only edits.
- **Writes:** atomic (temporary file and replacement), batched every 500 ms. `analisi.json.bak` of the previous version is kept.
- **iCloud:** Documents too may be synced with iCloud, like the Desktop. Before reading a data file the Store checks `NSURLUbiquitousItemDownloadingStatusKey`; if the file is not downloaded it calls `startDownloadingUbiquitousItem` and shows "Downloading from iCloud…". Reads and writes go through `NSFileCoordinator`.
- **`annotazioni.json`** (v2.4, §5.13), `version: 1`: `items[{id, page, kind: highlight|underline|strikeout|ink|rectangle|roundedRectangle|ellipse|line|arrow|speechBubble|star|polygon|textbox|note, color, fillColor?, lineWidth?, dash?, font?, alignment?, rect (page space), textRange?{start,length} (page characters, for the text tools), quads?[] (one rectangle per line), points?[[x,y]] (pen), text?, fontSize?, createdAt, updatedAt}]`. Atomic writes like the other files.
- **Chat and images:** never saved.

## 9. Performance and resources (M1, 8 GB)

- **First visible page:** within 1 s (Draghi, 73 pages) and within 2 s (600 pages).
- **Saved data visible:** within 1 s of the first page.
- **Scrolling:** 60 fps with 500 visible marks; overlay drawn only for the visible pages.
- **App memory:** under 400 MB with a 600-page PDF, excluding the `claude` processes.
- **Draghi block splitting:** under 5 s in the background, without blocking the interface.
- **Pro limits:** analysis only on command, a single process at a time, default effort (about 2k output tokens per block).
- **Measurements:** they are recorded in the measurements log.

## 10. Build and rules for the autonomous session

### 10.1 Project

- **Repository:** `git init` in the `LelePdf` folder. `.gitignore` for `*.xcodeproj`, `build/`, `DerivedData/`, `.DS_Store`. One local commit per milestone; no remote.
- **XcodeGen:** installed with `brew install xcodegen` if missing. `project.yml` defines the `LelePdf` (app) and `LelePdfTests` targets, with Swift 6 in language mode 6 and full concurrency checking.
- **Signing and sandbox:** sandbox disabled, hardened runtime disabled, ad-hoc signing. Bundle id `com.emanuele.LelePdf`.
- **Info.plist:**
  - `CFBundleDocumentTypes` for PDF (Viewer role, Alternate rank);
  - `LSApplicationCategoryType` = education;
  - `NSHumanReadableCopyright`.
- **Icon** (`scripts/make-icons.sh` with `sips`/`iconutil`):
  - source `logo/E.png` (500×500 with transparency);
  - large sizes: the whole logo on a white rounded square;
  - small sizes (up to 64 px) and the chat button: only the "EF" monogram, cropped;
  - if the author provides a 1024 px or vector version, it is regenerated from that.
- **Scripts:**
  - `scripts/build.sh`: `xcodegen` plus `xcodebuild -scheme LelePdf -configuration Debug -destination 'platform=macOS,arch=arm64' build`;
  - `scripts/test.sh`: unit tests;
  - `scripts/run.sh`: launches the app with one of the test PDFs.
- **End of the work:** Release build copied to `/Applications/LelePdf.app`.

### 10.2 Tests

- **Unit:**
  - cleaning (Draghi headers, Merck case license line, hyphenated words, letter-spaced text);
  - evaluation of the built-in outline (the Draghi one must come out "useless");
  - block rules;
  - matching of marks;
  - parser for the `{{m|…}}`, `[p. N]` and `<fuori>` markers;
  - alignment math;
  - map layout with no overlaps;
  - Store: round trip, atomic write, PDF rename;
  - Markdown export.
- **Fake CLI** (`scripts/fake-claude/`): a script that imitates the CLI with recorded responses and simulates success, invalid JSON, timeout, user not logged in, limit reached, chat stream. All tests of the Claude module use it.
- **Real calls:** only with `LELEPDF_REAL_CLAUDE=1`. **Budget for the whole development: at most 80 real calls** for analysis or contents and 25 chat questions, recorded in the measurements log.
- **Recording and replay:** every real response is saved as a fixture in `LelePdfTests/Fixtures/real/` (excluded from git, because it contains PDF text) and reused by the fake CLI. "Rerunning the suite" always means the fake CLI; real calls are repeated only when the prompt or schema changes. If the budget runs out, work goes on with the fixtures and this is noted in the build decision log.
- **Visual check at every milestone:** build, launch on the two PDFs, screenshots with computer-use, comparison with `design/DirezioneA-preview.html`.
- **Final phase (§12):** the source of the feedback is the session itself. Claude runs every use case (also via computer-use), records every deviation in the feedback log (case, severity, fix, re-check), fixes it, re-checks that case and reruns the suite with the fake CLI. It stops when all cases pass, or after 2 fix cycles per item: whatever remains open is marked "deferred" with the reason. At the end it writes the final report: what works, what is deferred and what the author should try first.

### 10.3 Behavior rules (to be copied into the developer instructions file)

1. Follow the milestones in order. Do not widen the scope beyond this document.
2. Do not stop to ask: decide, record it in the build decision log and carry on.
3. Every subagent is launched with the `sonnet` model.
4. The test PDFs are only read: they are not modified, not copied into the repository and not sent anywhere except to Claude through the app or the real tests.
5. Respect the real-call budget (§10.2).
6. Prompts and schemas live in `Resources/`, not written inside the code.
7. Local commit at the end of every milestone, with build and tests green.
8. If an iCloud dataless file is found, it is first downloaded (`brctl download`) and then read.
9. Long files (documents, large sources) are written in pieces of at most 12 KB, resuming from the partial file if a write is interrupted (a lesson from an earlier project).
10. No web search by subagents: everything needed is in this document, in the local SDK and in the spike notes.
11. macOS has no `timeout` command: in scripts use an alternative (for example `perl -e 'alarm N; exec @ARGV'`).

### 10.4 Session start (the author present for 5-10 minutes)

Before starting, with the author in front of the Mac:
1. `claude auth status` → logged in; record the plan in the measurements log.
2. Homebrew present; `brew install xcodegen`.
3. Ask right away for the computer-use permissions for `LelePdf` and `Finder` (needed for the visual checks), because afterwards the author will not be there.
4. Set a permission mode for the session that does not block the build, test and app-launch commands.
5. Download the logo and the two test PDFs from iCloud (`brctl download`) and check that they are readable.

From that moment no questions until the final report.

### 10.5 Continuity: full context and usage limits

- **New session for the build.** The build starts in a new session, not the one in which this specification was written, with the prompt of §10.6: this way it has the whole context space from the start.
- **State lives in files, not in the conversation.** The status file is the handover: current milestone, what is done, the precise next step, open problems, last commit, real calls used. It is updated at every completed step, not only at the end of a milestone, and before every long operation.
- **Light main context.** The heavy work (writing modules, tests, investigations) goes to the subagents on Sonnet. The main session coordinates, verifies and updates the state.
- **When the context fills up:** Claude Code summarizes the conversation by itself and carries on. After every summary, before continuing, the status file, the developer instructions and the specification section of the current milestone are reread.
- **When the subscription usage limit is reached:** the session stops until the limit resets. Nothing is lost, because the code is committed and the state is in files. After the reset the author writes "continue" in the same session (also from the Claude app on the phone); if the session was closed, a new one is opened with the resume prompt of §10.6.
- **When to do it:** better while the plan is still Max.

### 10.6 Start and resume prompts

Start, in a new session opened in the LelePdf project folder:

```
Read SPEC.md in full. Run the start-up of §10.4 with me present, then build LelePdf from M0 to M10 following the specification, without stopping to ask. Keep the status file updated at every step. All subagents on Sonnet.
```

Resume, after a usage limit or in a new session:

```
Resume the LelePdf build: read the status file, the developer instructions and the SPEC.md section of the current milestone, then continue from the next step without stopping.
```

## 11. Milestones and completion criteria

| # | Content | Done when |
|---|---|---|
| M0 | Foundations: repository, `project.yml`, empty app that launches, icon, document types, scripts, fake CLI, developer instructions file, test targets | `build.sh` and `test.sh` pass; the app opens from Finder and "Open with" on a PDF offers it |
| M1 | Reader: `DocumentGroup`, 3-column layout plus toolbar as in the design (right panel and map still placeholders), continuous PDF, page/zoom bar, thumbnails, built-in outline, search with scope, collapsible panels, last page remembered | Both PDFs open within 1 s; the screenshot respects the zones of the design; search finds "Orphan Drug Act" in the Merck case |
| M2 | Text pipeline with a debug overlay of the blocks (Debug menu) | Tests: Draghi header removed on at least 95% of the pages, "connectivity" rejoined, Merck case license line removed on all pages, exhibits of the case detected, blocks within the rules, Draghi outline judged useless, candidates that include the Draghi chapter titles; block boundaries checked by eye with the overlay screenshots |
| M3 | Store: fingerprint, JSON, index, atomic writes, Markdown export, iCloud files, progress | Round-trip test; renamed PDF → data found again; simulated interruption during a write → no corrupted file |
| M4 | Claude layer: CLI lookup, login, `BatchRunner`, `ChatSession`, errors and limits, generated contents | Tests with the fake CLI for all cases; with `LELEPDF_REAL_CLAUDE=1` correct generated contents for Draghi and Merck (compared by eye with the PDF) |
| M5 | Analysis, marks and rewrite: queue, prompt, matching, overlay of the 4 marks and repetitions, cards, placeholders, commands, pill and margin bars, errors, exhibit cross-references | 5 consecutive blocks of the Merck case and 3 of the Draghi report meet the targets of §7.5; on reopening everything appears within 1 s |
| M6 | Linked scrolling and hover between the two sides | Criteria of §5.8 measured and recorded; switch working; no bouncing |
| M7 | Edits: manual marks, text editing, targeted regeneration, restore, confirmation before overwriting, **manual contents T1-T4** (§5.3) | Everything stays after closing and reopening; the Markdown updates; a heading selected and added as T2 appears indented under the previous T1 and survives "Regenerate contents" |
| M7b | Free Preview-style annotations (§5.13): markup toolbar, highlighter, underline, strikethrough, pen, shapes, text box, notes, selection/move/delete, eraser, undo/redo, saving and export | All tools create, edit and delete annotations; everything stays after closing and reopening; the PDF on disk does not change (hash); the Markdown lists highlights, text boxes and notes |
| M8 | Maps: chapter and book, layout, mini and expanded views, hover/click linking, nodes from manual marks | Test with no overlaps; Merck case map readable in the screenshot; a manual rectangle appears as a node |
| M9 | Chat: button with the logo, panel, streaming, context and scope, clickable citations, "not in the PDF" chip, process life cycle | 5 test questions on the Merck case with the right pages; an external-knowledge question shows the chip; the process closes with the window or after 10 minutes of inactivity |
| M10 | Polish: empty and error states, Settings, **Summary Lab** (§5.14), performance measurements, installation in `/Applications`, README, use-case and feedback phase | All the use cases of §12 pass; feedback log closed or with the deferred items explicitly marked |

**Possible parallelization** (for a session with several agents): M0-M5 in sequence. Once the interfaces of `Store`, `Analysis` and `Reader` are stable, M6, M7, M8 and M9 touch different modules and can proceed in parallel, with integration and M10 at the end. File ownership: M6 writes only in `Sync/` and reads `Analysis`/`Rewrite`; M7 owns write access to `marks[]`/`links[]` and the editing views; M8 writes only in `Map/`; M9 only in `Chat/`. Every agent works in its own git worktree and integration happens with a dedicated merge before M10.

## 12. Use cases for the final phase

1. Open the Draghi report from Finder with "Open with" → first page within 1 s, contents generated with the chapters.
2. Open the Merck case → no built-in outline → plausible generated contents.
3. Analyze the first block of the Merck case → marks on the PDF, card on the right, pill and margin bar updated.
4. Press "Analyze the next block" three times → queue executed in order, progress correct.
5. "Analyze from here" on a paragraph in the middle of the Draghi report → the right block is analyzed.
6. Scroll the PDF and then the right panel with "Follow the PDF" on → the two sides stay aligned; off → independent.
7. Hover over a mark in the PDF → the counterpart on the right lights up, and vice versa.
8. Add a rectangle by hand, change it into a circle, remove one of Claude's marks, close and reopen → everything as left; map updated.
9. Edit the text of a card by hand, close and reopen → edit present, "edited" label; "Shorter" asks for confirmation.
10. Chapter and book map, "Expand", hover and click on a node → correct links.
11. Chat: question about the Merck case → answer with a correct, clickable `[p. N]`; question that requires external knowledge → "not in the PDF" chip.
12. Search for "Orphan Drug Act" in the chapter and in the whole PDF of the Merck case → correct results and counter (term chosen because it does not cross hyphenated words).
13. Rename and move the PDF, then reopen it → data found again.
14. Wrong CLI path in Settings → "Claude not connected" banner; reading and manual marks still work.
15. Fake CLI answering "limit reached" → banner with the reset time, no crash.
16. Click on an "Exhibit N · p. X" cross-reference in the rewrite → the PDF goes to the exhibit page.
17. `riscrittura.md` opened in a Markdown editor → structure and marks readable.
18. Chat on the Draghi report: during a conversation switch from "Chapter" to "Whole PDF" → the answer uses the new scope and the thread of the conversation stays.
19. Chat with the context budget lowered to 10k tokens in Settings → orange ring, then automatic summary; the conversation continues without errors.
20. Manual contents (v2.3): select a heading in the Merck case and add it as T1, then a subheading as T2 → the T2 appears indented under the T1; "Change level" and "Remove" work; after "Regenerate contents" and after closing and reopening the manual entries are still there.
21. Free annotations (v2.4): in the Merck case highlight a sentence in yellow, underline another, make a freehand drawing, add an arrow, a text box and a note; move the text box, change the color of the highlight, undo and redo, erase the drawing with the eraser; close and reopen → everything as left, PDF unchanged, highlights and notes in `riscrittura.md`.

## 13. Risks and countermeasures

| Risk | Countermeasure |
|---|---|
| Imprecise block splitting on complex layouts (Draghi boxes and columns) | Debug overlay, tests on the rules, fallback to groups of lines, stable ids with re-attachment |
| Too many marks slowing down scrolling | Per-page overlay only on the visible pages, precomputed rectangles per line |
| Stutter or bouncing in the linked scrolling | Reading-line algorithm with a guard on programmatic scrolls. If SwiftUI is not enough for the right panel, `NSScrollView` with SwiftUI content |
| Rewrite too long or not faithful | Length limit in the prompt, prompts as iterable files, measurements on the test PDFs |
| Claude output outside the schema | `--json-schema`, validation, one retry |
| Pro limits | Analysis only on command, one process at a time, call budget during development, warnings from the `rate_limit_event` events |
| Changes to CLI flags in future versions | At launch `claude --version` and the required flags are checked, with a clear error if they are missing |
| Dataless files on iCloud | Opening through the document system; in scripts `brctl download` before reading |

## 14. Non-blocking open points

1. The logo is 500×500: a 1024 px or vector version would make the icon sharper.
2. Format of the marks in the Markdown (`==…==` and similar, or `[[…]]` wikilinks for the Obsidian graph): to be decided when the second brain is connected.
3. **To remember · OCR of scanned PDFs** (paused by the author's decision). The author's idea: first run the PDF through a web OCR service such as iLovePDF, which adds the text to the PDF, and then open it in LelePdf, which then works normally. Caution: this means uploading the PDF to an external site, and some course materials (for example HBS cases) have a personal-use license. A free alternative that uploads nothing: `ocrmypdf`, installable with Homebrew, does the same thing on the Mac. Later, OCR can be integrated into the app with Apple's Vision.
