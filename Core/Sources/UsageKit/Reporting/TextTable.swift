/// Fixed-width column layout for terminal output.
///
/// Columns are sized from their contents so the result stays greppable and column-addressable with
/// `awk`, which is the point of a table rather than a paragraph.
enum TextTable {
    enum Alignment {
        case leading
        case trailing
    }

    static func render(
        header: [String],
        rows: [[String]],
        alignment: [Alignment] = []
    ) -> [String] {
        guard !rows.isEmpty else { return [] }
        let all = [header] + rows
        let widths = columnWidths(of: all)
        return all.map { row in
            row.enumerated()
                .map { index, cell in
                    let side = alignment.indices.contains(index) ? alignment[index] : .leading
                    return pad(cell, to: widths[index], as: side)
                }
                .joined(separator: "  ")
                .trimmedTrailingSpaces
        }
    }

    private static func columnWidths(of rows: [[String]]) -> [Int] {
        var widths: [Int] = []
        for row in rows {
            for (index, cell) in row.enumerated() {
                if index < widths.count {
                    widths[index] = max(widths[index], cell.count)
                } else {
                    widths.append(cell.count)
                }
            }
        }
        return widths
    }

    private static func pad(_ cell: String, to width: Int, as alignment: Alignment) -> String {
        let padding = String(repeating: " ", count: max(0, width - cell.count))
        switch alignment {
        case .leading: return cell + padding
        case .trailing: return padding + cell
        }
    }
}

extension String {
    var trimmedTrailingSpaces: String {
        var trimmed = self
        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
        return trimmed
    }
}
