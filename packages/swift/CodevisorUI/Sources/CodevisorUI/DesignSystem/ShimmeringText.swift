import QuartzCore
import SwiftUI
#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// A horizontal shimmer sweep masked to the content's shape, used for
/// ephemeral "in progress" states (agent status, running tool calls).
///
/// The sweep is a single Core Animation loop composited by the render server —
/// NOT a `TimelineView(.animation)`, which re-evaluates the body at display
/// refresh rate (up to 120 Hz) per shimmering view. During a busy turn several
/// rows shimmer at once; per-frame SwiftUI work stacked onto the streaming
/// updates was measurable main-thread cost for a purely cosmetic effect.
public struct ShimmerModifier: ViewModifier {
    var active: Bool

    public func body(content: Content) -> some View {
        content.overlay {
            if active {
                ShimmerSweep(shape: content)
            }
        }
    }
}

/// The moving highlight band, masked to `shape`. The platform view owns the
/// animation lifecycle, so inserting this view into an already-mounted hosting
/// controller cannot coalesce its starting state with its first rendered frame.
private struct ShimmerSweep<Shape: View>: View {
    let shape: Shape
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        PlatformShimmerView(colorScheme: colorScheme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A tight, bright glint whose motion lives entirely in Core Animation. Unlike
/// a one-shot SwiftUI `@State` flip, the layer can inspect whether its animation
/// is still installed and repair it after a remount, resize, or window move.
@MainActor
final class ShimmerSweepLayer: CAGradientLayer {
    static let animationKey = "codevisor.text-shimmer"
    private static let duration: CFTimeInterval = 1.2

    private var animatedSize: CGSize = .zero
    private var renderedColorScheme: ColorScheme?

    override init() {
        super.init()
        startPoint = CGPoint(x: 0, y: 0.5)
        endPoint = CGPoint(x: 1, y: 0.5)
        locations = [0, 0.18, 0.42, 0.5, 0.58, 0.82, 1]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(size: CGSize, colorScheme: ColorScheme) {
        guard size.width > 0, size.height > 0 else { return }

        // Keep the glint proportional to the rendered label. A fixed minimum
        // made short status text (for example, "Compacting context...") light
        // up almost all at once while longer tool-call titles showed the
        // intended tighter sweep.
        let bandWidth = max(size.width * 0.33, 1)
        let geometryChanged = animatedSize != size
        if geometryChanged {
            removeAnimation(forKey: Self.animationKey)
        }

        if geometryChanged || renderedColorScheme != colorScheme {
            let primary = CGColor(
                gray: colorScheme == .dark ? 1 : 0,
                alpha: 1
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frame = CGRect(x: 0, y: 0, width: bandWidth, height: size.height)
            colors = [
                primary.copy(alpha: 0)!,
                primary.copy(alpha: 0)!,
                primary.copy(alpha: 0.9)!,
                primary,
                primary.copy(alpha: 0.9)!,
                primary.copy(alpha: 0)!,
                primary.copy(alpha: 0)!,
            ]
            CATransaction.commit()
        }

        animatedSize = size
        renderedColorScheme = colorScheme
        ensureAnimation(containerWidth: size.width, bandWidth: bandWidth)
    }

    private func ensureAnimation(containerWidth: CGFloat, bandWidth: CGFloat) {
        guard animation(forKey: Self.animationKey) == nil else { return }

        // Move from just outside the leading edge to just outside the trailing
        // edge. The model layer stays at x = 0; only its presentation moves.
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -bandWidth
        sweep.toValue = containerWidth
        sweep.duration = Self.duration
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        add(sweep, forKey: Self.animationKey)
    }
}

#if canImport(AppKit)
    private struct PlatformShimmerView: NSViewRepresentable {
        let colorScheme: ColorScheme

        func makeNSView(context: Context) -> ShimmerLayerHostView {
            let view = ShimmerLayerHostView(frame: .zero)
            view.colorScheme = colorScheme
            return view
        }

        func updateNSView(_ nsView: ShimmerLayerHostView, context: Context) {
            nsView.colorScheme = colorScheme
            nsView.updateShimmer()
        }
    }

    @MainActor
    private final class ShimmerLayerHostView: NSView {
        let shimmerLayer = ShimmerSweepLayer()
        var colorScheme: ColorScheme = .light

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.addSublayer(shimmerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            updateShimmer()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateShimmer()
        }

        func updateShimmer() {
            shimmerLayer.update(size: bounds.size, colorScheme: colorScheme)
        }
    }
#elseif canImport(UIKit)
    private struct PlatformShimmerView: UIViewRepresentable {
        let colorScheme: ColorScheme

        func makeUIView(context: Context) -> ShimmerLayerHostView {
            let view = ShimmerLayerHostView(frame: .zero)
            view.colorScheme = colorScheme
            return view
        }

        func updateUIView(_ uiView: ShimmerLayerHostView, context: Context) {
            uiView.colorScheme = colorScheme
            uiView.updateShimmer()
        }
    }

    @MainActor
    private final class ShimmerLayerHostView: UIView {
        let shimmerLayer = ShimmerSweepLayer()
        var colorScheme: ColorScheme = .light

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(shimmerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateShimmer()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateShimmer()
        }

        func updateShimmer() {
            shimmerLayer.update(size: bounds.size, colorScheme: colorScheme)
        }
    }
#endif

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
