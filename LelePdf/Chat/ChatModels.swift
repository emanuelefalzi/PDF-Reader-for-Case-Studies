import Foundation

enum ChatScope: String, CaseIterable, Sendable, Identifiable {
    case visiblePages
    case section
    case chapter
    case wholeDocument

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visiblePages: String(localized: "Visible pages")
        case .section: String(localized: "Section")
        case .chapter: String(localized: "Chapter")
        case .wholeDocument: String(localized: "Whole PDF")
        }
    }
}

struct ChatTOCEntry: Sendable, Equatable {
    let title: String
    let level: Int
    let page: Int
}

struct ChatDocumentSnapshot: Sendable, Equatable {
    let title: String
    let fingerprint: String
    let pageTexts: [String]
    let toc: [ChatTOCEntry]
    let glossary: [String]
    let analyzedSummaries: [String]
    let currentPageIndex: Int
    let visiblePageRange: ClosedRange<Int>

    var pageCount: Int { pageTexts.count }
}

enum ChatSegment: Sendable, Equatable {
    case text(String)
    case citation(label: String, page: Int)
    case external(String)
}

enum ChatMessageRole: Sendable, Equatable {
    case user, assistant, note, divider
}

struct ChatMessage: Identifiable, Sendable, Equatable {
    let id: UUID
    let role: ChatMessageRole
    var rawText: String
    var segments: [ChatSegment]

    init(id: UUID = UUID(), role: ChatMessageRole, rawText: String, segments: [ChatSegment] = []) {
        self.id = id
        self.role = role
        self.rawText = rawText
        self.segments = segments
    }

    var firstCitationPage: Int? {
        segments.compactMap {
            if case .citation(_, let page) = $0 { return page }
            return nil
        }.first
    }
}

enum ChatBudgetLevel: Sendable, Equatable {
    case green, orange, red
}

struct ChatBudget: Sendable, Equatable {
    let usedTokens: Int
    let limit: Int

    var fraction: Double {
        guard limit > 0 else { return 1 }
        return min(1, Double(usedTokens) / Double(limit))
    }

    var level: ChatBudgetLevel {
        if fraction >= 0.85 { return .red }
        if fraction >= 0.60 { return .orange }
        return .green
    }

    var shouldOfferSummary: Bool { fraction >= 0.60 }
    var shouldAutoSummarize: Bool { fraction >= 0.85 }
}

struct ChatContextPlan: Sendable, Equatable {
    let systemPrompt: String
    let mode: ChatProcessMode
    let key: String
    let label: String
    let estimatedTokens: Int
    let includedPages: ClosedRange<Int>
}

enum ChatContextError: Error, Sendable, Equatable {
    case noText
    case promptMissing
    case searchDisabled
    case cannotWriteSearchIndex

    var userMessage: String {
        switch self {
        case .noText: String(localized: "The PDF text is not available yet.")
        case .promptMissing: String(localized: "The chat resource is not available.")
        case .searchDisabled: String(localized: "This scope exceeds 100 thousand tokens. Safe search in the PDF is not available.")
        case .cannotWriteSearchIndex: String(localized: "Can't prepare the PDF search index.")
        }
    }
}
