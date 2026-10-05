import Foundation

/// Term registry (SPEC §7.5 post-processing point 1, §7.6): decides which
/// `termId` to use for a new mark given the existing glossary. Pure, no
/// state: the caller (`AnalysisPostProcessor`) applies the result by
/// progressively accumulating new terms into the dictionary passed to the
/// next call, so two marks in the same block that introduce the same new
/// concept share the freshly minted `termId`.
enum TermRegistry {
    struct Resolution: Sendable, Equatable {
        var termId: String
        var isNew: Bool
    }

    /// Normalization for comparison (SPEC: "case-insensitive and with
    /// normalized whitespace"): lowercased, consecutive spaces collapsed to
    /// one, no leading/trailing spaces.
    static func normalize(_ term: String) -> String {
        term.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// SPEC §7.5 point 1: (1) same normalized `term` as an existing term →
    /// its `termId`, whatever Claude proposed; (2) otherwise the `termId`
    /// proposed by Claude if it already exists in the glossary; (3) otherwise
    /// a new, stable, increasing `termId`.
    static func resolve(term: String, proposedTermId: String?, in terms: [String: TermRecord]) -> Resolution {
        let normalized = normalize(term)
        if let existing = terms.first(where: { normalize($0.value.term) == normalized }) {
            return Resolution(termId: existing.key, isNew: false)
        }
        if let proposedTermId, terms[proposedTermId] != nil {
            return Resolution(termId: proposedTermId, isNew: false)
        }
        return Resolution(termId: nextTermId(after: terms), isNew: true)
    }

    /// `"t<N>"` with N = 1 + the highest existing numeric suffix among the
    /// glossary's `"t<N>"` keys (stable even with non-numeric ids or gaps in
    /// the numbering).
    static func nextTermId(after terms: [String: TermRecord]) -> String {
        let maxExisting = terms.keys.compactMap { key -> Int? in
            guard key.hasPrefix("t") else { return nil }
            return Int(key.dropFirst())
        }.max() ?? 0
        return "t\(maxExisting + 1)"
    }
}
