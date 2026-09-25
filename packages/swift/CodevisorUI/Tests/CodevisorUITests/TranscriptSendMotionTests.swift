import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Transcript send motion")
struct TranscriptSendMotionTests {
  /// Shaped after iMessage: the bubble rises 3–4% of its travel past its
  /// slot, rebounds once, and settles a little quicker than iMessage, in
  /// about half a second.
  @Test("The bubble overshoots its slot by a few percent of its travel, then settles")
  func bubbleOvershootsAndSettles() {
    let spring = TranscriptSendMotion.bubble
    let samples = stride(from: 0.0, through: 1.5, by: 1.0 / 240).map(spring.displacementFraction(at:))
    let overshoot = -(samples.min() ?? 0)
    #expect(overshoot > 0.025 && overshoot < 0.05)
    // One rebound: after the overshoot the motion never crosses back past
    // its slot by a visible amount.
    let peak = samples.firstIndex(of: -overshoot) ?? 0
    #expect(samples[peak...].allSatisfy { $0 < 0.005 })
    #expect(spring.settlingDuration() > 0.45 && spring.settlingDuration() < 0.7)
    #expect(abs(spring.displacementFraction(at: spring.settlingDuration())) <= 0.002)
  }

  @Test("History makes room without overshooting, ahead of the bubble")
  func contentNeverOvershoots() {
    let spring = TranscriptSendMotion.content
    let samples = stride(from: 0.0, through: 1.0, by: 1.0 / 240).map(spring.displacementFraction(at:))
    #expect(samples.allSatisfy { $0 >= 0 })
    #expect(spring.settlingDuration() < TranscriptSendMotion.bubble.settlingDuration())
    // Most of the room is made while the bubble is still near the composer.
    #expect(spring.displacementFraction(at: 0.15) < TranscriptSendMotion.bubble.displacementFraction(at: 0.15))
  }

  @Test("Core Animation receives the same physical spring")
  func coreAnimationParametersMatchTheModel() {
    let spring = TranscriptSendMotion.bubble
    let animation = TranscriptSendLayerAnimations.translation(CGSize(width: 0, height: 300), spring: spring)
    #expect(animation.mass == 1)
    #expect(abs(animation.stiffness - spring.stiffness) < 0.001)
    #expect(abs(animation.damping - spring.damping) < 0.001)
    #expect(animation.isAdditive)
    #expect(animation.duration == spring.settlingDuration())
  }
}

@Suite("Transcript send flight geometry")
struct TranscriptSendFlightGeometryTests {
  @Test("The bubble's last line starts on the composer's last line of glyphs")
  func textAlignsWithTheComposerGlyphs() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 44)
    let text = CGRect(x: 44, y: 704, width: 280, height: 40)
    let bubble = CGRect(x: 250, y: 400, width: 120, height: 56)

    let geometry = TranscriptSendFlightGeometry(editorFrame: editor, textRect: text, bubbleFrame: bubble)

    // Text inside the bubble sits 12 pt in and 8 pt up from its edges.
    let startBubble = bubble.offsetBy(dx: geometry.rowOffset.width, dy: geometry.rowOffset.height)
    #expect(startBubble.minX + 12 == text.minX)
    #expect(startBubble.maxY - 8 == text.maxY)
  }

  @Test("The scale pivots on the bubble's first glyph, which starts on the composer's")
  func scalePivotsOnTheTextOrigin() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 22)
    let text = CGRect(x: 40, y: 700, width: 40, height: 22)
    let bubble = CGRect(x: 300, y: 400, width: 64, height: 38)

    let geometry = TranscriptSendFlightGeometry(editorFrame: editor, textRect: text, bubbleFrame: bubble)

    #expect(geometry.textOrigin == CGPoint(x: 312, y: 430))
    // Translated by the offset, the pivot lands on the composer glyph.
    #expect(geometry.textOrigin.x + geometry.rowOffset.width == text.minX)
    #expect(geometry.textOrigin.y + geometry.rowOffset.height == text.maxY)
  }

  @Test("A scrolled draft aligns on the editor's visible last line")
  func scrolledDraftUsesTheVisibleText() {
    let editor = CGRect(x: 40, y: 500, width: 300, height: 200)
    // The draft is taller than the editor; its top is scrolled away.
    let text = CGRect(x: 40, y: 100, width: 300, height: 600)
    let bubble = CGRect(x: 60, y: 0, width: 300, height: 616)

    let geometry = TranscriptSendFlightGeometry(editorFrame: editor, textRect: text, bubbleFrame: bubble)

    // Aligned on the last visible line, not the scrolled-away top.
    #expect(geometry.rowOffset == CGSize(width: -32, height: 92))
  }

  @Test("Only a single line crossfades from the composer's glyphs")
  func onlySingleLinesCrossfade() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 88)
    let oneLine = TranscriptSendFlightGeometry(
      editorFrame: editor, textRect: CGRect(x: 40, y: 700, width: 120, height: 22),
      bubbleFrame: CGRect(x: 250, y: 400, width: 144, height: 38))
    #expect(oneLine.isSingleLine(textRect: CGRect(x: 40, y: 700, width: 120, height: 22), lineHeight: 22))

    // Three lines in both, but wrapped at different widths.
    let wrapped = TranscriptSendFlightGeometry(
      editorFrame: editor, textRect: CGRect(x: 40, y: 700, width: 300, height: 66),
      bubbleFrame: CGRect(x: 60, y: 300, width: 340, height: 82))
    #expect(!wrapped.isSingleLine(textRect: CGRect(x: 40, y: 700, width: 300, height: 66), lineHeight: 22))
  }
}
