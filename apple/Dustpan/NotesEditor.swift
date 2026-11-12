import SwiftUI

/// Notes in the task editor: Write is plain Markdown, Preview shows it formatted.
/// A note opens in Preview; an empty one opens ready to write.
struct NotesEditor: View {
    enum Mode { case write, preview }

    @Binding var text: String
    @State private var mode: Mode

    init(text: Binding<String>) {
        _text = text
        _mode = State(initialValue: text.wrappedValue.allSatisfy(\.isWhitespace) ? .write : .preview)
    }

    var body: some View {
        Section {
            switch mode {
            case .write:
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .accessibilityLabel("Notes, in Markdown")
            case .preview:
                if text.allSatisfy(\.isWhitespace) {
                    Text("No notes").foregroundStyle(.secondary)
                } else {
                    NoteView(text: text)
                }
            }
        } header: {
            HStack {
                Text("Notes")
                Spacer()
                Picker("Notes", selection: $mode) {
                    Text("Write").tag(Mode.write)
                    Text("Preview").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
