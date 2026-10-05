# Targeted regeneration of a block (SPEC §7.6)

You are regenerating the analysis of a single PDF block that has already
been analysed once. You receive the same kind of input as a first-time
analysis (document title, section path, previous block summary, glossary,
block text with exhibit citations substituted), plus:

- the block's CURRENT rewrite (the one shown to the user right now, as plain
  text with marked terms already resolved to readable words); and
- an instruction describing what the student wants changed: "shorter", "more
  detailed", or a free-text instruction they typed themselves.

Task: produce a new analysis for the same block, matching the same schema
(`analysis.schema.json`) and the same rules as a first-time analysis
(`analysis.md`) — same language, faithful, standalone, rewrite length within
60% of the block's word count, a SINGLE `rewrite` item (`kind: "outline"`)
holding the ordered `lines`, one `point`/`consequence` line per paragraph of
the source block with the paragraph's details as `subpoint`/`explanation`
lines right after it (max nesting 2, one idea per line, original order and
hierarchy preserved, numbers/dates/names copied exactly), `note`/`formula`/
`subheading`/`definition`/`example` used only when the block's own text
justifies them, at most 12
marks of 1-5 words copied exactly from the block, marked terms written
`{{mX|shown words}}`, links between marks/termIds.

Additional rules for this regeneration:

1. Follow the instruction. "Shorter" means noticeably more compact than the
   current rewrite (fewer lines, tighter sentences), not just a rephrasing
   of the same length. "More detailed" means adding lines or detail that the
   source block supports but the current rewrite omitted — never inventing
   anything the block doesn't say. A free-text instruction is applied as
   literally as the block's content allows.
2. Re-derive marks and links from scratch from the block text according to
   the new rewrite — do not simply keep the old ones. Reuse the glossary
   `termId` for a concept you already used before, exactly as in a
   first-time analysis, so the concept map does not fragment into duplicate
   nodes for the same thing.
3. The block's manually-added marks are not part of this input and are kept
   by the app separately: you only need to produce Claude's own marks for
   the new rewrite.
4. Output language: keep writing in the language of the block text (the
   language the PDF is written in), for every field including `title` and
   every line's `text`. The language of the instruction never changes it: an
   Italian instruction such as "più breve" on an English block still gets an
   English rewrite.
