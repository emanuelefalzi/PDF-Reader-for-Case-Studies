import CoreGraphics

/// Pure math for the chat button (SPEC §5.9): "44 pt round... 16 pt from
/// the window's bottom-right corner". Separate from `ChatOverlay` so a
/// test can verify the resulting rectangle without mounting SwiftUI
/// (add a layout test).
enum ChatButtonLayout {
    static let diameter: CGFloat = 44
    static let margin: CGFloat = 16

    /// The button's rectangle in the window's coordinate space (origin at the
    /// top left, like `GeometryReader`/SwiftUI).
    static func frame(windowSize: CGSize) -> CGRect {
        CGRect(
            x: windowSize.width - margin - diameter,
            y: windowSize.height - margin - diameter,
            width: diameter,
            height: diameter
        )
    }
}
