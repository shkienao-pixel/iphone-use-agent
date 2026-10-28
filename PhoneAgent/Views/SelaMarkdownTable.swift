import Foundation

/// The same column parser feeds native Grid layout and offline regressions.
enum SelaMarkdownTable {
    static func cells(in line: String) -> [String] {
        let line = line.trimmingCharacters(in: .whitespaces)
        var cells = line.components(separatedBy: "|")
        // Only the optional outside delimiters are structural. Interior empty
        // cells, including the first/last column, must retain their position.
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
    }

    static func startsTable(header: String, separator: String?) -> Bool {
        guard header.contains("|"), let separator else { return false }
        let headings = cells(in: header), alignment = cells(in: separator)
        return headings.count > 1 && headings.count == alignment.count && isSeparator(alignment)
    }

    static func rows(in text: String) -> [[String]] {
        text.components(separatedBy: .newlines).map { cells(in: $0) }.filter { !isSeparator($0) }
    }
}
