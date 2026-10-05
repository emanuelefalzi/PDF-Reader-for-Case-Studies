# AIPDF UI design

Imported on 2026-09-10 from Claude Design.

- Chosen direction: **A**

## Files

| File | What it is |
|---|---|
| `DirezioneA.dc.html` | Original in Claude Design's canvas format. It is the reference for the implementation. |
| `DirezioneA-preview.html` | The same page without the canvas tags: it opens with a double click in any browser. It shows the "sidebar open" and "Follow the PDF on" state. |

Not imported:
- `support.js`: runtime of the Claude Design canvas (React), not needed locally. It can be downloaded again with DesignSync.
- `DirezioneB.dc.html`: the other proposed direction, available on request.

## What Direction A contains

A 1440×900 macOS window, macOS 26 style with translucent surfaces.

| Area | Size | Content |
|---|---|---|
| Titlebar | 56 px high | Traffic lights, two panel buttons, file name and "Subject profile · Law · 612 pages", pill "Rewrite ch. 4 of 12" with a progress bar, Actions menu, "Search in chapter" field, snapshot button |
| Left sidebar | 264 px wide, collapsible | Pages / Chapters / Map segmented control; concept map of the chapter (nodes colored by category, labeled relations, "+ 13 nodes" node, + and Expand buttons); legend |
| Center | rest of the width | "Page 42 of 612 · Zoom 118% · Highlighting by category on" bar; PDF page with filled highlights where the term is defined and underlines where it recurs |
| Right panel | 392 px wide | "Simplified rewrite" with Ch. › section path, "Follow the PDF" switch, cards ("In two lines" summary, Definition box, bullet list, highlighted callout), page chip on every card, ⌥⌥ hint |
| Floating chat | 680 px wide, bottom center | Opens with a double ⌥. Context pill ("Ch. 4 · pp. 42–43 · visible text"), answer with page chips and a dashed chip for information not in the PDF, "Go to point", input field with a "Page 42" chip |

### Colors

| Role | Background | Text | Border / legend | Underline for repetitions |
|---|---|---|---|---|
| Accent (progress, page chip, send) | `#E7EFFE` | `#2F6FED` | `#C2D6FA` | |
| Definition | `#DBE7FF` | `#153E9E` | `#9BB9F7` | |
| Concept | `#D3EFE2` | `#0F5C42` | `#8CCFB4` | `#57B894` |
| Person / date | `#E9DCFB` | `#5B2C9B` | `#BFA0EC` | `#A57FE0` |
| Rule / formula | `#FBE3C4` | `#8A4A05` | `#E7B172` | |

## Corrections already decided

- At the bottom of the sidebar the text "Local analysis · no data sent" is not true: the PDF text is sent to Claude. It must be replaced with "Text sent to Claude · results saved locally".

## Still to be defined

Dark mode and states are missing (analysis not started yet, chapter being rewritten, expanded map, Claude not connected). They are decided together with the specification.
