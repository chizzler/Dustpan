import DustpanCore
import SwiftUI

/// A day's planned time against the day length, "3h / 8h", red when over. Nothing when none is planned.
struct DayLoadText: View {
    let load: DayLoad
    let dayLength: Int

    var body: some View {
        if load.planned > 0 {
            Text("\(formatMinutes(load.planned)) / \(formatMinutes(dayLength))")
                .font(.callout)
                .foregroundStyle(load.over ? Color.red : Color.secondary)
                .lineLimit(1)
                .help("Planned against your day length")
        }
    }
}
