// Reader module (SPEC §6.2).
//
// `PDFKitView` wraps `PDFView` in an `NSViewRepresentable`; `PDFReaderBridge`
// carries commands from the model to the view without feedback loops;
// `PDFReaderCoordinator` observes PDFKit notifications and updates the
// model. `PageZoomBar`, `ThumbnailsSidebar` and `SearchBar` are the UI
// pieces of this module (SPEC §5.1, §5.3 Pages, §5.10). The marks overlay
// and the selection mini bar arrive in M2/M5/M7.
