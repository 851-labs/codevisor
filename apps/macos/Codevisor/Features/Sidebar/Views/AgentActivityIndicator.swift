import AppKit
import SwiftUI

/// Herdr-inspired working glyph: its ten braille frames advance at roughly
/// eight steps per second in the harness icon's slot.
///
/// The frame cycle is a `CAKeyframeAnimation` on a layer's `contents`, NOT a
/// `TimelineView(.animation)` — the same lesson already recorded on
/// `ShimmeringText`, but with more bite here. A `TimelineView` re-evaluates its
/// body on the main run loop, so this indicator froze solid for the duration of
/// any main-thread hitch (notably the transcript rebuild on a tab switch),
/// which read as a broken spinner while every render-server-driven
/// `ProgressView` on screen kept turning. Discrete frame swapping cannot be
/// composited in pure SwiftUI at all — a `Timer` or `PhaseAnimator` stalls
/// exactly the same way — so the cycle is handed to CoreAnimation wholesale.
///
/// The trade is that the glyph must be rasterized against a known color instead
/// of inheriting the ambient foreground style, so callers pass the color their
/// surrounding row already uses.
struct AgentActivityIndicator: View {
    /// Matches what the enclosing row would have tinted the glyph.
    var color: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrailleSpinnerLayer(color: color, isAnimated: !reduceMotion)
            .frame(width: BrailleSpinnerFrames.size.width, height: BrailleSpinnerFrames.size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working")
            .help("Chat is working")
    }
}

/// The ten braille frames, pre-rasterized per (color, appearance, scale).
///
/// Bounded and tiny: at most a couple of colors per appearance, so a plain
/// dictionary needs no eviction policy.
@MainActor
private enum BrailleSpinnerFrames {
    static let glyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let size = CGSize(width: 14, height: 14)
    /// Eight steps per second, as before.
    static let cycleDuration = Double(glyphs.count) / 8

    private struct Key: Hashable {
        let color: Color
        let appearance: String
        let scale: CGFloat
    }

    private static var cache: [Key: [CGImage]] = [:]

    static func images(color: Color, scale: CGFloat) -> [CGImage] {
        let key = Key(
            color: color,
            appearance: NSApp.effectiveAppearance.name.rawValue,
            scale: scale
        )
        if let cached = cache[key] { return cached }
        let images = glyphs.compactMap { render($0, color: color, scale: scale) }
        // A partial set would animate a short, wrong cycle; don't cache it.
        guard images.count == glyphs.count else { return images }
        cache[key] = images
        return images
    }

    private static func render(_ glyph: String, color: Color, scale: CGFloat) -> CGImage? {
        let pixelsWide = Int(size.width * scale)
        let pixelsHigh = Int(size.height * scale)
        guard pixelsWide > 0, pixelsHigh > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        rep.size = NSSize(width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // `.primary`/`.secondary` resolve differently per appearance, so bake
        // them against the app's current one (as MenuIconRasterizer does).
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let text = NSAttributedString(
                string: glyph,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor(color),
                ]
            )
            let bounds = text.boundingRect(
                with: NSSize(width: size.width, height: size.height),
                options: [.usesLineFragmentOrigin]
            )
            text.draw(
                at: NSPoint(
                    x: (size.width - bounds.width) / 2,
                    y: (size.height - bounds.height) / 2
                ))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// Hosts the pre-rasterized frames on a layer and cycles them in the render
/// server, so the animation is immune to main-thread stalls.
private struct BrailleSpinnerLayer: NSViewRepresentable {
    let color: Color
    let isAnimated: Bool

    private static let animationKey = "brailleFrames"

    @MainActor
    final class Coordinator {
        var appliedKey: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        let scale =
            view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        // Rebuild only when something that changes the pixels or the timing
        // moves; this runs on every SwiftUI invalidation of the enclosing row.
        let key = "\(color.hashValue)-\(scale)-\(isAnimated)-\(NSApp.effectiveAppearance.name.rawValue)"
        guard context.coordinator.appliedKey != key else { return }
        context.coordinator.appliedKey = key

        let images = BrailleSpinnerFrames.images(color: color, scale: scale)
        guard let first = images.first else { return }
        layer.contentsScale = scale
        layer.removeAnimation(forKey: Self.animationKey)
        layer.contents = first
        guard isAnimated, images.count > 1 else { return }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.duration = BrailleSpinnerFrames.cycleDuration
        animation.repeatCount = .infinity
        // Phase-align to an absolute grid so every spinner on screen steps in
        // lockstep regardless of when it mounted — the old absolute-time frame
        // derivation gave that for free, and losing it would be visible with
        // several running chats listed together.
        let now = CACurrentMediaTime()
        let phase = now.truncatingRemainder(dividingBy: animation.duration)
        animation.beginTime = layer.convertTime(now, from: nil) - phase
        layer.add(animation, forKey: Self.animationKey)
    }
}
