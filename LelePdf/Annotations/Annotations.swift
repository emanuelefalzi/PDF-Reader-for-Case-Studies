// Annotations module (SPEC §6.2, §5.13, v2.4): free annotations in the style
// of Preview, separate from the 4 marks (§5.4/Analysis) and never sent to
// Claude.
//
// - `AnnotationModel`: `Annotation`/`AnnotationsRecord`, Codable/Sendable,
//   plus the small geometry types of its own (`AnnotationRect` etc., not a
//   bare `CGRect`: this avoids any doubt about retroactive Sendable/Codable
//   conformances on CoreGraphics under Swift 6 strict concurrency).
// - `AnnotationPalette`: the 5 Preview colors (yellow default, green,
//   blue, pink, purple) and the last color/width per tool (UserDefaults).
// - `AnnotationGeometry` / `InkSmoothing` / `AnnotationHitTesting`: pure
//   geometry (resizing, handles, pen smoothing/simplification, per-type
//   hit-testing), testable without AppKit/PDFKit.
// - `AnnotationUndoStack`: pure undo/redo (before/after by id), separate
//   from the bridge to AppKit's `UndoManager` in `AnnotationController`.
// - `AnnotationController` (+ `AnnotationController+Tools`): per-window state
//   (MainActor), CRUD, current tool/color, saving.
// - `AnnotationRenderer`: draws the annotations as native `PDFAnnotation`s
//   on the in-memory `PDFDocument`; they are written to the file only on
//   command or when the automatic option is explicitly enabled.
// - `ShapePDFAnnotation`: subclass for the shapes PDFKit has no native
//   subtype for (rounded rectangle, speech bubble, star, polygon).
// - `AnnotationOverlayView` (+ Drawing/Selection): mouse interaction, on top
//   of `MarksOverlayView` in the same `PDFView` (Reader).
// - `AnnotationTextBoxEditor` / `AnnotationNotePopover`: text editor and
//   note popover, as in Preview.
// - `AnnotationToolbarLabels` / `AnnotationToolbar` / `AnnotationColorPopovers`:
//   the Annotate bar (SwiftUI), Preview's labels and icons (§5.13).
