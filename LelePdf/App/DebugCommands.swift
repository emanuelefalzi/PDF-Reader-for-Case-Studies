import SwiftUI

/// "Debug" menu (SPEC §11 row M2): shows/hides the overlay of block
/// boundaries above the PDF (`Reader/DebugOverlay.swift`). Always
/// present, not only in Debug builds: it lets the author verify
/// segmentation even after M2, with new PDFs.
struct DebugCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandMenu("Debug") {
            Toggle("Show Blocks", isOn: Binding(
                get: { model?.debugShowBlocks ?? false },
                set: { model?.debugShowBlocks = $0 }
            ))
            .disabled(model == nil)

            Divider()

            // SPEC §5.8 "How it is measured", M6 deliverable 4 (fallback to
            // an XCUITest target, see `SyncMeasurementRunner`): active only with
            // `LELEPDF_MEASURE=1` (otherwise `model.syncCoordinator.measurement`
            // stays `nil` and the run writes nothing).
            Button("Measure Scrolling") {
                guard let model else { return }
                Task { await model.runMeasurementSequence() }
            }
            .disabled(model == nil)
        }
    }
}
