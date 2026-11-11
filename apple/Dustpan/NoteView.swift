import DustpanCore
import SwiftUI

/// A task's notes, formatted. Links open in the browser; nothing else is loaded.
struct NoteView: View {
    let text: String

    var body: some View {
        NoteBlocks(blocks: parseMarkdown(text))
            .textSelection(.enabled)
    }
}

/// Blocks one under another. Quotes and list items hold blocks of their own.
private struct NoteBlocks: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { NoteBlock(block: blocks[$0]) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoteBlock: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let nodes):
            Text(attributed(nodes))
        case .heading(let level, let nodes):
            Text(attributed(nodes)).font(headingFont(level))
        case .code(let body, _):
            ScrollView(.horizontal) {
                Text(body).font(.body.monospaced()).padding(8)
            }
            .background(.quaternary, in: .rect(cornerRadius: 6))
        case .quote(let inner):
            NoteBlocks(blocks: inner)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .list(let ordered, let start, let items, let checks):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + n, check: checks?[n])
                        NoteBlocks(blocks: items[n])
                    }
                }
            }
        case .table(let align, let head, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        ForEach(head.indices, id: \.self) { c in
                            Text(attributed(head[c])).bold().gridColumnAlignment(columnAlignment(align[c]))
                        }
                    }
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { Text(attributed(rows[r][$0])) }
                        }
                    }
                }
            }
        case .image(_, let alt):
            // Dustpan doesn't fetch attachments yet.
            Label("Image: \(alt.isEmpty ? "attachment" : alt)", systemImage: "photo").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, check: Bool??) -> some View {
        if let check = check ?? nil {
            Image(systemName: check ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(check ? "Done" : "Not done")
        } else {
            Text(ordered ? "\(number)." : "•").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }

    private func columnAlignment(_ align: MarkdownAlignment?) -> HorizontalAlignment {
        switch align {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }
}
