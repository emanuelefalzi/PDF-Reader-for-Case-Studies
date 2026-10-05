import SwiftUI

/// Shared container for the right-hand panel cards (SPEC §5.6): thin
/// border, rounded corners, light shadow.
struct CardContainer<Content: View>: View {
    var accentBorder: Color?
    var accentBackground: Color?
    /// Thin bar on the left in the document's subject color, shown when this
    /// card is the one under the mouse (in the PDF or the panel) or at the
    /// reading position. It makes clear which card belongs to which section.
    /// Same idiom already used by the `callout` (SPEC §5.6, "colored left
    /// border"), not a new design-system element. `nil` (default): no bar.
    var accentBarColor: Color?
    /// Alternative to `accentBarColor`: the bar, observed on its own
    /// (`FocusAccentBar`, `RewriteRowStack.swift`), for the given block, so a
    /// focus change re-evaluates neither the card nor the stack.
    var focusAccentBlockId: String?
    var focusAccentForced = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentBackground ?? DSColor.cardBackground)
        .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(accentBorder ?? DSColor.borderCard, lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if let accentBarColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentBarColor)
                    .frame(width: 3)
                    .padding(.vertical, 3)
            } else if let focusAccentBlockId {
                FocusAccentBar(blockId: focusAccentBlockId, forced: focusAccentForced)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// Page chip (SPEC §5.6 "click -> the PDF jumps to the start of the block"),
/// styled as in the design ("p. 42", accent background/border/text).
struct PageChip: View {
    let page: Int
    var label: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label ?? "p. \(page + 1)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DSColor.accent)
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .background(DSColor.accentBackground)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DSColor.accentBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

/// Chapter/section title (SPEC §5.6 "in document order").
struct HeadingRow: View {
    let title: String
    let level: Int

    var body: some View {
        Text(title)
            .font(.system(size: level == 1 ? 15 : 13, weight: level == 1 ? .bold : .semibold))
            .foregroundStyle(DSColor.textPrimary)
            .padding(.top, level == 1 ? 10 : 4)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pointer to an Exhibit (SPEC §5.6 "Exhibit 5 · p. 19 ↗").
struct ExhibitRow: View {
    let label: String
    let page: Int
    @Environment(DocumentModel.self) private var model

    var body: some View {
        Button {
            model.goToPage(page)
        } label: {
            Text(RewriteViewModel.exhibitLabel(label: label, page: page))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DSColor.accent)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
