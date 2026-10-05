import SwiftUI

struct ChatOverlay: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        // SPEC §5.9: round button 16 pt from the bottom-right corner OF THE
        // WINDOW, above all panels.
        ZStack(alignment: .bottomTrailing) {
            // Invisible rectangle ONLY to fill the window (it anchors the
            // button/panel to the corner instead of letting the parent ZStack
            // of `ThreePaneLayout` center them): `allowsHitTesting(false)`
            // keeps it from intercepting clicks on the rest of the window,
            // including the two draggable dividers. That was exactly the
            // reported bug "I can't resize the two panes". It is a sibling,
            // not an ancestor, of the button/scrim/panel below: its
            // `allowsHitTesting(false)` does not affect them.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            if model.chatController.isPresented {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .transition(.opacity)

                ChatPanel(model: model)
                    .frame(width: 680)
                    .frame(maxWidth: 680, maxHeight: 540)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button { model.toggleChat() } label: {
                Image("ChatLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .help("Ask the PDF")
            .accessibilityLabel("Ask the PDF")
            .padding(ChatButtonLayout.margin)
        }
        .animation(.easeInOut(duration: 0.18), value: model.chatController.isPresented)
        // Esc: handled centrally by `ThreePaneLayout.onExitCommand` (it must
        // give the chat priority over the expanded concept map, SPEC M8).
    }
}

private struct ChatPanel: View {
    let model: DocumentModel

    var body: some View {
        @Bindable var chat = model.chatController
        VStack(spacing: 9) {
            contextPill(chat)
            VStack(spacing: 0) {
                header(chat)
                Divider().opacity(0.45)
                conversation(chat)
                if let warning = chat.warningMessage { banner(warning, color: .orange) }
                if let error = chat.errorMessage { banner(error, color: .red) }
                if chat.budget.shouldOfferSummary { summaryOffer(chat) }
                input(chat)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.82), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        }
    }

    private func contextPill(_ chat: ChatController) -> some View {
        HStack(spacing: 7) {
            Circle().fill(DSColor.accent).frame(width: 7, height: 7)
            Text(chat.contextLabel).font(.system(size: 11))
        }
        .foregroundStyle(DSColor.textPrimary)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.75), lineWidth: 0.5))
    }

    private func header(_ chat: ChatController) -> some View {
        HStack(spacing: 10) {
            Text("Chat with the PDF").font(.headline)
            if chat.isPreparing { ProgressView().controlSize(.small) }
            Spacer()
            ContextRing(budget: chat.budget)
            Button("New conversation") { chat.newConversation(snapshot: model.chatSnapshot()) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    private func conversation(_ chat: ChatController) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    if chat.messages.isEmpty {
                        Text("Ask something about the document.")
                            .foregroundStyle(DSColor.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    }
                    ForEach(chat.messages) { message in
                        ChatMessageView(message: message) { model.navigateFromChatCitation(pageNumber: $0) }
                            .id(message.id)
                    }
                    if chat.isResponding { ProgressView().controlSize(.small) }
                }
                .padding(15)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .onChange(of: chat.messages) { _, messages in
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func input(_ chat: ChatController) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField("Ask the PDF something…", text: Bindable(chat).inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { chat.submit(snapshot: model.chatSnapshot()) }

            Picker("Scope", selection: Bindable(chat).scope) {
                ForEach(ChatScope.allCases) { scope in
                    Text("\(scope.label) · \(chat.pageEstimate(scope))").tag(scope)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)

            Button { chat.submit(snapshot: model.chatSnapshot()) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(DSColor.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isResponding)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(.white.opacity(0.38))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
            .background(color.opacity(0.08))
    }

    private func summaryOffer(_ chat: ChatController) -> some View {
        Button("The conversation is long \u{b7} Summarize and continue") {
            chat.summarizeAndContinue(snapshot: model.chatSnapshot())
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.vertical, 5)
    }
}

private struct ChatMessageView: View {
    let message: ChatMessage
    let navigate: (Int) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Text("You").font(.caption).foregroundStyle(DSColor.textSecondary)
                Text(message.rawText).font(.system(size: 13)).textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(ChatParagraphGrouping.blocks(from: message.segments).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
                if let page = message.firstCitationPage {
                    Button("Go to point ↗") { navigate(page) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        case .note:
            Text(message.rawText)
                .font(.caption)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.vertical, 3)
        case .divider:
            HStack { Divider(); Text(message.rawText).font(.caption); Divider() }
                .foregroundStyle(DSColor.textTertiary)
        }
    }

    /// A `.flow` is a single `Text` (text + citation chips in the same
    /// `AttributedString`, `ChatInlineText`): it flows and wraps as one
    /// paragraph instead of breaking at every citation. The chip's
    /// placeholder link is intercepted here and turned into page navigation,
    /// without ever actually being opened.
    @ViewBuilder
    private func blockView(_ block: ChatParagraphBlock) -> some View {
        switch block {
        case .flow(let segments):
            Text(ChatInlineText.attributedString(for: segments))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard let page = ChatInlineText.citationPage(from: url) else { return .systemAction }
                    navigate(page)
                    return .handled
                })
        case .external(let text):
            VStack(alignment: .leading, spacing: 3) {
                Text("not in the PDF").font(.caption2.weight(.semibold))
                Text(text).font(.caption).textSelection(.enabled)
            }
            .foregroundStyle(Color(rgb: 0x7A6A45))
            .padding(7)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color(rgb: 0xD9C08A))
            }
        }
    }
}

private struct ContextRing: View {
    let budget: ChatBudget

    private var color: Color {
        switch budget.level {
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.black.opacity(0.1), lineWidth: 3)
            Circle().trim(from: 0, to: budget.fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .help("Context: \(budget.usedTokens) of \(budget.limit) tokens")
        .accessibilityLabel("Context \(Int(budget.fraction * 100)) percent")
    }
}
