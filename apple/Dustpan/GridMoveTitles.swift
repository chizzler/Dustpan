import DustpanCore
import SwiftUI

extension GridMove {
    var title: String {
        switch self {
        case .earlier: "15 Minutes Earlier"
        case .later: "15 Minutes Later"
        case .dayBefore: "Day Before"
        case .dayAfter: "Day After"
        case .shorter: "Shorter"
        case .longer: "Longer"
        case .startEarlier: "Start Earlier"
        case .startLater: "Start Later"
        case .unschedule: "Unschedule"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .earlier: KeyboardShortcut(.upArrow, modifiers: [])
        case .later: KeyboardShortcut(.downArrow, modifiers: [])
        case .dayBefore: KeyboardShortcut(.leftArrow, modifiers: [])
        case .dayAfter: KeyboardShortcut(.rightArrow, modifiers: [])
        case .shorter: KeyboardShortcut(.upArrow, modifiers: .shift)
        case .longer: KeyboardShortcut(.downArrow, modifiers: .shift)
        case .startEarlier: KeyboardShortcut(.upArrow, modifiers: [.option, .shift])
        case .startLater: KeyboardShortcut(.downArrow, modifiers: [.option, .shift])
        case .unschedule: KeyboardShortcut("u", modifiers: [])
        }
    }

    /// The move for an arrow key with these modifiers, as on the desktop and the web app.
    init?(arrow key: KeyEquivalent, modifiers: EventModifiers) {
        let found = Self.allCases.first { move in
            move.shortcut.key == key && move.shortcut.modifiers == modifiers.intersection([.shift, .option, .command, .control])
        }
        guard let found, found != .unschedule else { return nil }
        self = found
    }
}
