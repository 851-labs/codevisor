import SwiftUI

/// A horizontal shimmer sweep masked to the content's shape, used for
/// ephemeral "in progress" states (agent status, running tool calls).
///
/// The sweep is a single `repeatForever` animation composited by the render
/// server — NOT a `TimelineView(.animation)`, which re-evaluates the body at
/// display refresh rate (up to 120 Hz) per shimmering view. During a busy
/// turn several rows shimmer at once; per-frame SwiftUI work stacked onto the
/// streaming updates was measurable main-thread cost for a purely cosmetic
/// effect.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    @State private var sweep = false

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let band = max(width * 0.4, 30)
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: sweep ? width : -band)
                        .animation(
                            .linear(duration: 1.4).repeatForever(autoreverses: false),
                            value: sweep
                        )
                    }
                    .mask(content)
                }
                .onAppear { sweep = true }
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

    /// The turn is over but the agent still owns background work and will
    /// start a new turn on its own when it settles.
    static func waitingOnBackgroundTask(_ description: String) -> ShimmeringText {
        ShimmeringText(text: "Waiting on \(description)...")
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
