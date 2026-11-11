import DustpanCore
import SwiftUI

/// The Filter page's query, what it finds, and Save as View.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    /// What the query finds, or why it can't run.
    let status: String
    let failed: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading) {
            QueryField(query: $model.filterQuery, focusRequest: model.filterFocus)
                .labelsHidden()
            HStack(alignment: .firstTextBaseline) {
                Text(status)
                    .foregroundStyle(failed ? .red : .secondary)
                Spacer()
                Button("Save as View…", action: save)
                    .disabled(failed || model.filterQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func save() {
        model.editingView = ViewDraft(query: model.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
