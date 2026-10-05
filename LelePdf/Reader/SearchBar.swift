import SwiftUI

/// "Search in chapter" field with a scope picker, in the toolbar (SPEC §5.1,
/// §5.10). The actual field is `SearchFieldView` (a hand-driven
/// `NSSearchField`), not a SwiftUI `TextField` with `@FocusState`, which did
/// not always move the window's real focus when hosted in a `ToolbarItem`.
/// The "n of N" counter sums the PDF results and those of the right panel
/// (`DocumentModel.searchTotalCount`).
struct SearchBar: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textTertiary)
                SearchFieldView(model: model)
                    .frame(maxWidth: .infinity)

                if model.searchTotalCount > 0 {
                    Text("\((model.currentSearchResultIndex ?? 0) + 1) of \(model.searchTotalCount)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DSColor.textTertiary)
                } else if !model.searchQuery.isEmpty {
                    Text("0 results")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DSColor.textTertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 190, height: 26)
            .background(Color.black.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Picker("Scope", selection: $model.searchScope) {
                Text("Chapter").tag(SearchScope.capitolo)
                Text("Whole PDF").tag(SearchScope.tuttoIlPDF)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .labelsHidden()
        }
        .onChange(of: model.searchQuery) { _, _ in model.runSearch() }
        .onChange(of: model.searchScope) { _, _ in model.runSearch() }
    }
}
