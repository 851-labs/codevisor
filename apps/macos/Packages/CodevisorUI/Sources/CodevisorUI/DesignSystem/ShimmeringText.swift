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
public struct ShimmerModifier: ViewModifier {
    var active: Bool

    public func body(content: Content) -> some View {
        content.overlay {
            // A fresh subview per activation: its `@State phase` starts at 0 and
            // its `.onAppear` kicks the sweep, so re-activating shimmer always
            // restarts cleanly instead of resuming a parked animation.
            if active {
                ShimmerSweep(shape: content)
            }
        }
    }
}

/// The moving highlight band, masked to `shape`.
///
/// `GeometryReader` reports width 0 on its first pass, so the animated band is
/// keyed with `.id(width)`: it re-mounts once the real width lands and animates
/// its offset directly between endpoints computed from THAT width. Deriving the
/// endpoints from a stale zero width was why the band parked over the trailing
/// glyphs and never swept the leading text.
private struct ShimmerSweep<Shape: View>: View {
    let shape: Shape

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ShimmerBand(width: width)
                // Re-mount when the measured width settles so the sweep uses the
                // real width; rounded so sub-point jitter doesn't restart it.
                .id(Int(width.rounded()))
        }
        .mask(shape)
    }
}

/// One left-to-right pass of a tight, bright glint, looping forever. Created
/// with a known `width`, so `-band → width` are correct from the first frame.
private struct ShimmerBand: View {
    let width: CGFloat
    @State private var sweptToEnd = false

    public var body: some View {
        // A bright glint with a soft, center-peaked core: brightest at the
        // middle and easing out through a gradient to the edges, so it reads as
        // a defined highlight (not a hard bar, not a broad wash) sweeping across.
        // Keep the glint proportional to the rendered label. A fixed minimum
        // made short status text (for example, "Compacting context...") light
        // up almost all at once while longer tool-call titles showed the
        // intended tighter sweep.
        let band = max(width * 0.33, 1)
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: Color.primary.opacity(0), location: 0.18),
                .init(color: Color.primary.opacity(0.9), location: 0.42),
                .init(color: Color.primary, location: 0.5),
                .init(color: Color.primary.opacity(0.9), location: 0.58),
                .init(color: Color.primary.opacity(0), location: 0.82),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: band)
        // false → band just off the leading edge; true → just off the trailing
        // edge, so it sweeps the full [0, width].
        .offset(x: sweptToEnd ? width : -band)
        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: sweptToEnd)
        .onAppear { sweptToEnd = true }
    }
}

extension View {
    /// Sweeps a shimmer across the view while `active` is true.
    public func shimmering(_ active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

/// A text label with a horizontal shimmer sweep, used for ephemeral agent
/// status while the agent is working.
public struct ShimmeringText: View {
    var text: String = "Thinking..."
    var font: Font = .callout

    public init(text: String = "Thinking...", font: Font = .callout) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .shimmering()
            .accessibilityLabel(text)
    }
}

extension ShimmeringText {
    public static var thinking: ShimmeringText {
        ShimmeringText(text: "Thinking...")
    }

    public static var startingAgent: ShimmeringText {
        ShimmeringText(text: "Starting agent...")
    }

    public static var compactingContext: ShimmeringText {
        ShimmeringText(text: "Compacting context...")
    }

    /// The turn is over but the agent still owns background work and will
    /// start a new turn on its own when it settles.
    public static func waitingOnBackgroundTask(_ description: String) -> ShimmeringText {
        ShimmeringText(text: "Waiting on \(description)...")
    }

    /// The user's prompt is held server-side while the harness updates and
    /// dispatches automatically once the update finishes.
    public static func waitingOnHarnessUpdate(_ harnessName: String) -> ShimmeringText {
        ShimmeringText(text: "Waiting for \(harnessName) to finish updating...")
    }
}

public struct AgentStatusText: View {
    var text: String
    var font: Font = .callout

    public init(text: String, font: Font = .callout) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityLabel(text)
    }
}

extension AgentStatusText {
    public static var contextCompacted: AgentStatusText {
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
