// Rewrite module (SPEC §6.2): the right-hand "Simplified rewrite" panel.
//
// - `RewriteViewModel`: pure mapping from segments to rows, queue/estimated-
//   time labels, and layout constants.
// - `MarkedTextBuilder`: resolved segments (`AnalysisController.ResolvedSegment`,
//   `{{mX|...}}` markers already resolved upstream) -> plain text plus marked
//   ranges; pure (the "text attribute building" step).
// - `MarkedTextView`: `NSTextView` wrapped for SwiftUI that draws the 4
//   marks as custom attributes (SPEC §6.2 "Rewrite").
// - `BlockCardView` / `RewriteRows.swift`: card for an analyzed block,
//   placeholders (not analyzed / queued / in progress / error), Exhibit row,
//   section title.
// - `RewritePanel`: content of the right-hand panel (`App/RightPanel.swift`
//   hosts the header, this content, and the bottom button).
