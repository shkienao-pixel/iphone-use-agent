import SwiftUI

/// Native text layout: no HTML, scripts or remote image loading.
struct SelaMarkdownText: View {
    let text: String
    private struct Block: Identifiable {
        let id: Int
        var kind: Int // paragraph, heading, list, code, table
        var text: String
        var marker = ""
        var level = 0
    }
    private var blocks: [Block] {
        var result: [Block] = [], paragraph: [String] = [], code: [String] = [], table: [String] = []
        var inCode = false
        func append(_ kind: Int, _ value: String, marker: String = "", level: Int = 0) {
            result.append(.init(id: result.count, kind: kind, text: value, marker: marker, level: level))
        }
        func flush() {
            if !paragraph.isEmpty { append(0, paragraph.joined(separator: "\n")); paragraph = [] }
            if !table.isEmpty { append(4, table.joined(separator: "\n")); table = [] }
        }
        let lines = text.components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                if inCode { append(3, code.joined(separator: "\n")); code = [] }
                inCode.toggle(); continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let startsTable = SelaMarkdownTable.startsTable(header: line, separator: index + 1 < lines.count ? lines[index + 1] : nil)
            if line.hasPrefix("|") || startsTable || (!table.isEmpty && line.contains("|")) {
                if !paragraph.isEmpty { flush() }; table.append(line); continue
            }
            if !table.isEmpty { flush() }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush(); append(1, String(line.dropFirst(hashes + 1)), level: hashes); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); append(2, String(line.dropFirst(2)), marker: "•"); continue
            }
            if let range = line.range(of: #"^\d+[.)、]\s+"#, options: .regularExpression) {
                flush(); append(2, String(line[range.upperBound...]), marker: String(line[range]).trimmingCharacters(in: .whitespaces)); continue
            }
            paragraph.append(raw)
        }
        flush(); if !code.isEmpty { append(3, code.joined(separator: "\n")) }
        return result
    }
    private func inline(_ value: String) -> AttributedString {
        // Some model replies close bold after Chinese punctuation immediately
        // before another word. CommonMark's delimiter rules leave those stars
        // literal. Preserve links/code and explicitly apply this bold span.
        let pattern = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
        let source = value as NSString
        var output = AttributedString(), cursor = 0
        func parsed(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
        for match in pattern.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            output.append(parsed(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            var strong = parsed(source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces))
            strong.inlinePresentationIntent = .stronglyEmphasized
            output.append(strong)
            cursor = NSMaxRange(match.range)
        }
        output.append(parsed(source.substring(from: cursor)))
        return output
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                switch block.kind {
                case 1:
                    Text(inline(block.text)).font(block.level <= 2 ? .title3.bold() : .headline)
                        .padding(.top, block.id == 0 ? 0 : 6).textSelection(.enabled)
                case 2:
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(block.marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .leading)
                        Text(inline(block.text)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case 3:
                    ScrollView(.horizontal) { Text(block.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(12) }
                        .background(AgentPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                case 4:
                    let rows = SelaMarkdownTable.rows(in: block.text)
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                                GridRow {
                                    ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                                        Text(inline(cell.element)).font(row.offset == 0 ? .subheadline.bold() : .subheadline)
                                            .frame(maxWidth: 240, alignment: .leading).textSelection(.enabled)
                                    }
                                }
                                if row.offset == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(12)
                    }.background(AgentPalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                default:
                    Text(inline(block.text)).lineSpacing(5).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).font(.body).tint(AgentPalette.accent)
    }
}
