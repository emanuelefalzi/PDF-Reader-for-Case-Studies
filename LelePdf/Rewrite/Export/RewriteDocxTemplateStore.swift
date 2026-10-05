import Foundation

/// Resolves the ACTIVE Word template for export: either the one the user
/// chose in Settings (already fully extracted into Application Support by
/// `WordTemplateSettings`, one file per entry of the original archive; see
/// there), or the built-in template (`RewriteDocxDefaultTemplate`) when none
/// has been chosen or the folder is not readable.
///
/// "Missing style -> nearest built-in style, reported": `word/styles.xml`/
/// `word/numbering.xml` of the chosen template are COMPLETED (never replaced)
/// with the built-in fragment for each styleId that is missing. All the other
/// files of the chosen template (theme, fontTable, images, relationships,
/// `docProps`) stay BYTE FOR BYTE the original ones, so the only file this
/// code really replaces is `word/document.xml` (written by
/// `RewriteDocxExporter`).
enum RewriteDocxTemplateStore {
    struct Resolved: Sendable {
        /// Every file of the final archive, relative path (as inside the zip,
        /// e.g. "word/styles.xml") -> bytes. It does not yet include
        /// `word/document.xml` (added by `RewriteDocxExporter`).
        var entries: [String: Data]
        /// Built-in styleIds used because they were absent from the chosen
        /// template (reported to the user: "and says so").
        var fallbacksUsed: [RewriteDocxStyle]
        /// styleIds present in the ACTIVE template before any patching.
        var availableStyleIds: Set<String>
        /// For each role, the styleId that `document.xml` must write (the
        /// template's REAL one, found by id or by name ignoring case, spaces
        /// and hyphens, or else the built-in one just injected). A missing
        /// role means `Heading4`, which the template does not have (T4 falls
        /// back to Heading3).
        var styleMap: RewriteDocxStyleMap
        /// `true` if the template the user chose was not readable (folder
        /// missing/empty/corrupt): the built-in one was used SILENTLY only if
        /// nothing had ever been chosen; this field distinguishes "no template
        /// chosen" from "template chosen but unreadable", for a different
        /// message in the interface.
        var customTemplateUnreadable: Bool
    }

    static func resolve(customTemplateDirectory: URL?) -> Resolved {
        guard let customTemplateDirectory,
              let stored = try? loadStoredEntries(from: customTemplateDirectory), !stored.isEmpty else {
            if customTemplateDirectory != nil {
                return resolveDefault(customTemplateUnreadable: true)
            }
            return resolveDefault(customTemplateUnreadable: false)
        }
        return resolveCustom(stored)
    }

    // MARK: - Template chosen by the user

    private static func resolveCustom(_ stored: [String: Data]) -> Resolved {
        var entries = stored
        entries.removeValue(forKey: "word/document.xml") // replaced by the exporter

        let stylesText = entries["word/styles.xml"].flatMap { String(data: $0, encoding: .utf8) } ?? RewriteDocxDefaultTemplate.defaultStylesXML
        let numberingText = entries["word/numbering.xml"].flatMap { String(data: $0, encoding: .utf8) } ?? RewriteDocxDefaultTemplate.defaultNumberingXML

        let templateStyles = parseStyles(in: stylesText)
        let availableIds = Set(templateStyles.map(\.styleId))
        var styleMap = RewriteDocxStyleMap(ids: [:])
        for style in RewriteDocxStyle.allCases {
            if let found = match(style, in: templateStyles) { styleMap.ids[style] = found.styleId }
        }
        var fallbacksUsed: [RewriteDocxStyle] = []
        var patchedStyles = stylesText
        var patchedNumbering = numberingText

        // Styles of the style mapping table: a patch here is what must be
        // REPORTED. Excludes Heading4 (its own rule below) and Normal/Title/
        // Subtitle (our own scaffolding, never part of the requested mapping;
        // injected silently just below if they are really missing).
        // `insertedNumberingFragments`: point and sub-point share the SAME
        // built-in `abstractNum`/`num` (`RewriteDocxDefaultTemplate`, the same
        // idea as the user's real template: one list, two `w:ilvl`), so if both
        // are missing the fragment must be injected only once, not twice (a
        // duplicate `w:abstractNumId` would not be valid XML).
        var insertedNumberingFragments: Set<String> = []
        for style in RewriteDocxStyle.reportableStyles {
            guard styleMap.ids[style] == nil else { continue }
            fallbacksUsed.append(style)
            styleMap.ids[style] = style.rawValue
            patchedStyles = insert(RewriteDocxDefaultTemplate.fallbackStyleXML(for: style), before: "</w:styles>", in: patchedStyles)
            if let numberingFragment = RewriteDocxDefaultTemplate.fallbackNumberingXML(for: style), insertedNumberingFragments.insert(numberingFragment).inserted {
                patchedNumbering = insert(numberingFragment, before: "</w:numbering>", in: patchedNumbering)
            }
        }
        // Heading4 (T4, if present: Heading3 as well, or Heading4 if the
        // template has it): a built-in Heading4 is NOT injected if missing;
        // it falls back to Heading3 (handled by
        // `RewriteDocxExporter.headingStyleId`, not here).
        // `markedTerm` (styleId "IntenseEmphasis") gets the same silent
        // treatment as normal/title/subtitle: it is only needed if the user
        // turns on "Emphasise marked terms", and is never part of the mapping
        // table that must be reported as a patch.
        for style: RewriteDocxStyle in [.normal, .title, .subtitle, .markedTerm] where styleMap.ids[style] == nil {
            styleMap.ids[style] = style.rawValue
            patchedStyles = insert(RewriteDocxDefaultTemplate.fallbackStyleXML(for: style), before: "</w:styles>", in: patchedStyles)
        }

        // "List Paragraph" and step numbering (`RewriteDocxDefaultTemplate`):
        // ALWAYS added, not tied to any styleId of the mapping table. They are
        // only needed by `steps`/`table`, rows left over for an analysis saved
        // before the outline format, which no template (chosen or built-in)
        // defines by itself.
        if !availableIds.contains(RewriteDocxDefaultTemplate.listParagraphStyleId) {
            patchedStyles = insert(RewriteDocxDefaultTemplate.listParagraphStyleXML, before: "</w:styles>", in: patchedStyles)
        }
        patchedNumbering = insert(RewriteDocxDefaultTemplate.stepsNumberingXML, before: "</w:numbering>", in: patchedNumbering)

        entries["word/styles.xml"] = Data(patchedStyles.utf8)
        entries["word/numbering.xml"] = Data(patchedNumbering.utf8)

        return Resolved(entries: entries, fallbacksUsed: fallbacksUsed, availableStyleIds: availableIds, styleMap: styleMap, customTemplateUnreadable: false)
    }

    // MARK: - Built-in template (none chosen, or chosen but unreadable)

    private static func resolveDefault(customTemplateUnreadable: Bool) -> Resolved {
        let entries: [String: Data] = [
            "[Content_Types].xml": Data(RewriteDocxTemplates.contentTypesXML.utf8),
            "_rels/.rels": Data(RewriteDocxTemplates.packageRelsXML.utf8),
            "word/_rels/document.xml.rels": Data(RewriteDocxTemplates.documentRelsXML.utf8),
            "word/styles.xml": Data(RewriteDocxDefaultTemplate.defaultStylesXML.utf8),
            "word/numbering.xml": Data(RewriteDocxDefaultTemplate.defaultNumberingXML.utf8),
        ]
        return Resolved(
            entries: entries, fallbacksUsed: [],
            availableStyleIds: Set(RewriteDocxStyle.allCases.map(\.rawValue)),
            styleMap: .builtIn,
            customTemplateUnreadable: customTemplateUnreadable
        )
    }

    // MARK: - Reading the extracted folder (Application Support, `WordTemplateSettings`)

    private static func loadStoredEntries(from directory: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(base) else { continue }
            var relative = String(fullPath.dropFirst(base.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty, let data = try? Data(contentsOf: url) else { continue }
            result[relative] = data
        }
        return result
    }

    // MARK: - Text helpers

    /// A style of `word/styles.xml` as the lookup needs it.
    struct TemplateStyle: Equatable, Sendable {
        var styleId: String
        var name: String
        var isCharacter: Bool
    }

    private static let styleBlockPattern = try! NSRegularExpression(pattern: #"<w:style\b[^>]*?(?:/>|>.*?</w:style>)"#, options: [.dotMatchesLineSeparators])
    private static let styleIdAttributePattern = try! NSRegularExpression(pattern: #"w:styleId="([^"]+)""#)
    private static let styleTypeAttributePattern = try! NSRegularExpression(pattern: #"w:type="([^"]+)""#)
    private static let styleNamePattern = try! NSRegularExpression(pattern: #"<w:name\s+w:val="([^"]*)""#)

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// All paragraph and character styles of the template (tables and
    /// numberings serve no role), in file order.
    static func parseStyles(in stylesXML: String) -> [TemplateStyle] {
        let ns = stylesXML as NSString
        return styleBlockPattern.matches(in: stylesXML, range: NSRange(location: 0, length: ns.length)).compactMap { match -> TemplateStyle? in
            let block = ns.substring(with: match.range)
            let openingTag = String(block.prefix(while: { $0 != ">" }))
            guard let styleId = firstGroup(styleIdAttributePattern, in: openingTag),
                  case let type = firstGroup(styleTypeAttributePattern, in: openingTag) ?? "paragraph", // OOXML: without w:type it is a paragraph
                  type == "paragraph" || type == "character" else { return nil }
            let name = firstGroup(styleNamePattern, in: block) ?? styleId
            return TemplateStyle(styleId: styleId, name: name, isCharacter: type == "character")
        }
    }

    /// The template style that stands in for `style`. First the styleId equal
    /// to the expected one (ignoring case/spaces/hyphens), then the visible
    /// name, then any styleId among the role's keys: `GrassoTitoli`,
    /// `grassotitoli` and "Grasso Titoli" are the same style. Only styles of
    /// the same kind are compared.
    static func match(_ style: RewriteDocxStyle, in templateStyles: [TemplateStyle]) -> TemplateStyle? {
        let candidates = templateStyles.filter { $0.isCharacter == style.isCharacterStyle }
        let keys = style.lookupKeys
        let ownKey = RewriteDocxStyle.lookupKey(style.rawValue)
        return candidates.first { RewriteDocxStyle.lookupKey($0.styleId) == ownKey }
            ?? candidates.first { keys.contains(RewriteDocxStyle.lookupKey($0.name)) }
            ?? candidates.first { keys.contains(RewriteDocxStyle.lookupKey($0.styleId)) }
    }

    private static func insert(_ fragment: String, before marker: String, in xml: String) -> String {
        guard let range = xml.range(of: marker) else { return xml + fragment } // marker absent (malformed): the fragment is not lost anyway
        return xml.replacingCharacters(in: range, with: fragment + marker)
    }
}

/// For each export role, the styleId that `document.xml` writes (see
/// `RewriteDocxTemplateStore.Resolved.styleMap`).
struct RewriteDocxStyleMap: Sendable, Equatable {
    var ids: [RewriteDocxStyle: String]

    /// The built-in template has all roles, with the styleIds from `rawValue`.
    static let builtIn = RewriteDocxStyleMap(ids: Dictionary(uniqueKeysWithValues: RewriteDocxStyle.allCases.map { ($0, $0.rawValue) }))

    func id(for style: RewriteDocxStyle) -> String { ids[style] ?? style.rawValue }
    func has(_ style: RewriteDocxStyle) -> Bool { ids[style] != nil }
}
