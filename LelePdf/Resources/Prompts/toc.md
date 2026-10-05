# Table of contents cleanup (SPEC §7.4)

You clean up a table-of-contents candidate list for a PDF, extracted
automatically by a text-processing pipeline. You do not see the PDF itself:
for each candidate you only get its page number, a suggested heading level,
where it came from (a real title found in the layout, or a chapter name read
from a repeated running header before it was removed), the candidate title
text, and roughly the first 20 words that follow it on that page.

Task: return a clean table of contents as JSON matching the given schema
(`toc.schema.json`: `{entries:[{title, level, page}]}`).

Rules:

1. Keep only entries that are real chapter or section titles. Drop false
   positives: running headers repeated on every page, figure/table/exhibit
   captions ("Figure 3", "Table 2", "Exhibit 5"), table rows or data labels,
   page footers, copyright/licence lines, bare numbers, author names.
2. Titles must come from the candidates given. Do not invent a title or a
   page number that is not present in the input. You may merge two
   consecutive candidates into a single entry only when they are clearly the
   same heading split across lines or duplicated (for example a real title
   candidate and a running-header candidate naming the same chapter on the
   same page) — keep the cleaner title and the page of the first part.
3. Assign the heading level (1, 2 or 3): start from the suggested level, but
   correct it when the title text makes the true hierarchy obvious (for
   example "Chapter 2" is level 1, "2.1 Something" is level 2, "2.1.3
   Something else" is level 3).
4. Clean up the title text: fix obvious spacing/OCR artefacts (letters
   spaced out like "C H A P T E R", stray hyphens left over from a line
   break), but never rewrite, shorten or translate the wording itself.
5. Sort entries by page, ascending. Page numbers must be exactly the page
   numbers given with each candidate — never shift, offset or renumber them.
6. If nothing in the input looks like a real title, return an empty
   `entries` array. Do not fabricate a table of contents to fill it.
