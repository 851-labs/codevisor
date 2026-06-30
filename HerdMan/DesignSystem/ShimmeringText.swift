import SwiftUI

/// A text label with a horizontal shimmer sweep, used for the ephemeral
/// "Thinking…" indicator while the agent is working.
struct ShimmeringText: View {
    var text: String = "Thinking…"
    var font: Font = .callout

    var body: some View {
        TimelineView(.animation) { context in
            let cycle = 1.4
            let phase = CGFloat(context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle)
            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .overlay {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(width * 0.4, 30))
                        .offset(x: -width * 0.4 + phase * (width * 1.4))
                    }
                    .mask(Text(text).font(font))
                }
                .accessibilityLabel(text)
        }
    }
}

#Preview {
    ShimmeringText()
        .padding()
}
