import AppKit

/// Selection mini bar (SPEC §5.7, v2.3 §5.3): appears near the text
/// selection in the PDF (marks + T1-T4) or near a clicked mark (Change +
/// Remove). **Extensible** (M7b appends annotation tools to the same bar):
/// buttons are passed in as groups (`configure(groups:)`), never wired one
/// by one here, so adding a group for the annotation tools (M7b) will not
/// require touching this view.
final class SelectionMiniBar: NSView {
    struct Item {
        var symbolName: String?
        var title: String?
        var tint: NSColor?
        var action: () -> Void
    }

    private var items: [Item] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Groups separated by a thin vertical divider.
    func configure(groups: [[Item]]) {
        subviews.forEach { $0.removeFromSuperview() }
        items = groups.flatMap { $0 }

        var x: CGFloat = 6
        let height: CGFloat = 28
        var flatIndex = 0
        for (groupIndex, group) in groups.enumerated() {
            guard !group.isEmpty else { continue }
            if groupIndex > 0 {
                let separator = NSBox(frame: NSRect(x: x, y: 4, width: 1, height: height - 8))
                separator.boxType = .separator
                addSubview(separator)
                x += 9
            }
            for item in group {
                let width = buttonWidth(for: item)
                let button = NSButton(frame: NSRect(x: x, y: 2, width: width, height: height - 4))
                configureButton(button, item: item, tag: flatIndex)
                addSubview(button)
                x += width + 2
                flatIndex += 1
            }
        }
        frame.size = CGSize(width: x + 4, height: height)
    }

    /// The bar now also hosts text items longer than "T1" (e.g. "Analyze this
    /// section"), which the earlier fixed width would have cut off. It
    /// measures the actual text with the button's own font instead of using a
    /// fixed number; for the T1-T4 buttons the result stays practically
    /// identical to 30 pt.
    private func buttonWidth(for item: Item) -> CGFloat {
        guard let title = item.title else { return 28 }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return width + 16
    }

    private func configureButton(_ button: NSButton, item: Item, tag: Int) {
        button.tag = tag
        button.bezelStyle = .inline
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        if let symbolName = item.symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.title) {
            button.image = image
            button.imagePosition = .imageOnly
            if let tint = item.tint { button.contentTintColor = tint }
        } else {
            button.title = item.title ?? ""
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }
        button.target = self
        button.action = #selector(handleTap(_:))
    }

    @objc private func handleTap(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].action()
    }
}
