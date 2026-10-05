# Fixed technical contract (not editable)

These rules stay mandatory even when the rewrite instructions above have been
customised in the Summary Lab:

1. Return only data that conforms to the JSON schema provided separately.
2. Output language: write EVERY text field -- `title` and every line's `text`
   (point, subpoint, explanation, note, formula, consequence, subheading,
   definition, example),
   mark terms and link labels -- in the language of the block text, the same
   language the PDF is written in. The language of these instructions (or of
   any customised instructions) never decides the output language: an
   English block gets an English rewrite, an Italian block an Italian one.
3. In a line's `text`, wrap every mention linked to a mark in the exact
   format `{{mX|words shown}}`, where `mX` is the id of an item in `marks` of
   the same response.
4. Never create markers for ids missing from `marks`, and never change the
   syntax: double curly braces, vertical bar and mark id.
