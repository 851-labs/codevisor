import SwiftUI

/// A horizontal shimmer sweep masked to the content's shape, used for
/// ephemeral "in progress" states (agent status, running tool calls).
struct ShimmerModifier: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { context in
                let cycle = 1.4
                let phase = CGFloat(context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycle) / cycle)
                content
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
                        .mask(content)
                    }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Sweeps a shimmer across the view while `active` is true.
    func shimmering(_ active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

/// A text label with a horizontal shimmer sweep, used for ephemeral agent
/// status while the agent is working.
struct ShimmeringText: View {
    var text: String = "Thinking..."
    var font: Font = .callout

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .shimmering()
            .accessibilityLabel(text)
    }
}

extension ShimmeringText {
    static var thinking: ShimmeringText {
        ShimmeringText(text: "Thinking...")
    }

    static var startingAgent: ShimmeringText {
        ShimmeringText(text: "Starting agent...")
    }

    static var compactingContext: ShimmeringText {
        ShimmeringText(text: "Compacting context...")
    }
}

struct AgentStatusText: View {
    var text: String
    var font: Font = .callout

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityLabel(text)
    }
}

extension AgentStatusText {
    static var contextCompacted: AgentStatusText {
        AgentStatusText(text: "Context compacted")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ShimmeringText.thinking
        ShimmeringText.startingAgent
        ShimmeringText.compactingContext
        AgentStatusText.contextCompacted
    }
    .padding()
}
