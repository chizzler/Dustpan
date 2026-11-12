import SwiftUI

/// The d, w and m keys for Day, Week and Month. The toolbar's segmented picker can't carry a key per segment,
/// so these buttons hold them, out of sight: the picker is what's seen and read by VoiceOver.
struct CalendarModeKeys: View {
    @Binding var mode: CalendarMode

    var body: some View {
        ZStack {
            ForEach(CalendarMode.allCases) { choice in
                Button(choice.title) { mode = choice }
                    .keyboardShortcut(KeyEquivalent(choice.key), modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
