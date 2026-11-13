/// A default reminder picker's selection.
enum ReminderChoice: Hashable {
    case none
    case minutes(Int64)
    /// Asks for an offset of its own.
    case custom

    init(_ minutes: Int64?) {
        self = minutes.map(ReminderChoice.minutes) ?? .none
    }
}
