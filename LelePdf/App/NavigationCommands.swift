import SwiftUI

/// "Go" menu ("Go (previous/next page)"): SPEC does not fix a
/// shortcut for these two commands (§5.1 lists only ⌘O/⌘F/⌘J/⌘↩/⌘⇧1/
/// ⌘⇧2/⌥⌘L/⌘+/⌘−; ⌘⌥1/⌘⌥2 replaced M1's ⌃⌘S/⌥⌘I, later moved to
/// ⌘⇧1/⌘⇧2), so the choice is technical, decided and noted instead of
/// stopping to ask: ⌘[ / ⌘], the same "square brackets" convention
/// already used for back/forward in many Mac apps (Safari, Xcode), free in
/// this app (see `MenuCommandTable`, no other command uses it).
struct NavigationCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandMenu("Go") {
            Button("Previous Page") { model?.goToPreviousPage() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model == nil)

            Button("Next Page") { model?.goToNextPage() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model == nil)
        }
    }
}
