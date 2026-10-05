import SwiftUI

/// "Claude is analyzing" placeholder shown during a targeted regeneration
/// (SPEC §5.5/§5.6, with an "x" button to cancel), in place of the card
/// content; the title and page chip stay (`BlockCardView`; separate file to
/// keep files under ~12 KB).
struct RegeneratingRow: View {
    let humanLabel: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Claude is analyzing \(humanLabel)")
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(DSColor.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

/// "Rewrite Like This…" popover/sheet (SPEC §5.6): text field for the
/// free-form instruction.
struct CustomInstructionSheet: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rewrite Like This…").font(.system(size: 13, weight: .semibold))
            TextField("Instruction for Claude", text: $text, axis: .vertical)
                .lineLimit(3 ... 6)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Regenerate") { onSubmit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
