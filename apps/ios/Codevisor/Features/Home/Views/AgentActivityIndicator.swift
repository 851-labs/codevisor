import SwiftUI

/// The macOS sidebar's Herdr-inspired working glyph, ported: ten braille
/// frames advancing at roughly eight steps per second in the status slot.
struct AgentActivityIndicator: View {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { context in
            let frame = reduceMotion ? Self.frames[0] : Self.frame(at: context.date)
            Text(frame)
                // `.footnote` = 13 pt at the default size; scales with the
                // Dynamic Type session titles beside it.
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.identity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private static func frame(at date: Date) -> String {
        let tick = Int(date.timeIntervalSinceReferenceDate * 8)
        return frames[tick % frames.count]
    }
}
