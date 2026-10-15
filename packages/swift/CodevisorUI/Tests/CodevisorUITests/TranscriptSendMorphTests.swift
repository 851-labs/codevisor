import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Transcript send morph geometry")
struct TranscriptSendMorphTests {
  @Test("The bubble starts as the composer's whole text line, text at its leading edge")
  func startsAsTheTextLine() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 44)
    let text = CGRect(x: 40, y: 711, width: 36, height: 22)

    let start = TranscriptSendMorphGeometry.startBubble(editorFrame: editor, textRect: text)

    #expect(start.minX == editor.minX - 12)
    #expect(start.maxX == editor.maxX + 12)
    #expect(start.minX + 12 == text.minX)
    #expect(start.minY + 8 == text.minY)
    #expect(start.height == text.height + 16)
  }

  @Test("A single line ends trailing-anchored at the landing, as wide as its glyphs")
  func singleLineEndsAtTheTrailingEdge() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 44)
    let text = CGRect(x: 40, y: 711, width: 36, height: 22)
    let start = TranscriptSendMorphGeometry.startBubble(editorFrame: editor, textRect: text)
    let landing = TranscriptSendLanding(trailing: 386, top: 120, maxBubbleWidth: 330)

    let end = TranscriptSendMorphGeometry.predictedEnd(
      start: start, editorFrame: editor, textRect: text, lineHeight: 22, landing: landing)

    #expect(end.maxX == landing.trailing)
    #expect(end.minY == landing.top)
    #expect(end.width == text.width + 24)
    #expect(end.height == start.height)
  }

  @Test("Wrapped text ends as wide as the widest bubble")
  func wrappedTextEndsAtTheWidestBubble() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 88)
    let text = CGRect(x: 40, y: 704, width: 300, height: 66)
    let start = TranscriptSendMorphGeometry.startBubble(editorFrame: editor, textRect: text)
    let landing = TranscriptSendLanding(trailing: 386, top: 120, maxBubbleWidth: 250)

    let end = TranscriptSendMorphGeometry.predictedEnd(
      start: start, editorFrame: editor, textRect: text, lineHeight: 22, landing: landing)

    #expect(end.width == landing.maxBubbleWidth)
    #expect(end.maxX == landing.trailing)
  }

  @Test("A long single line is capped at the widest bubble")
  func longLineIsCapped() {
    let editor = CGRect(x: 40, y: 700, width: 300, height: 44)
    let text = CGRect(x: 40, y: 711, width: 290, height: 22)
    let start = TranscriptSendMorphGeometry.startBubble(editorFrame: editor, textRect: text)
    let landing = TranscriptSendLanding(trailing: 386, top: 120, maxBubbleWidth: 200)

    let end = TranscriptSendMorphGeometry.predictedEnd(
      start: start, editorFrame: editor, textRect: text, lineHeight: 22, landing: landing)

    #expect(end.width == 200)
  }

  @Test("The leading edge moves on a quick spring that never overshoots; the rise is slower")
  func slideLeadsTheRise() {
    let slide = TranscriptSendMotion.bubbleSlide
    let rise = TranscriptSendMotion.bubble
    let samples = stride(from: 0.0, through: 1.0, by: 1.0 / 240).map(slide.displacementFraction(at:))
    #expect(samples.allSatisfy { $0 >= 0 })
    #expect(slide.settlingDuration() < rise.settlingDuration())
    #expect(slide.displacementFraction(at: 0.1) < 0.35)
    #expect(rise.displacementFraction(at: 0.1) > slide.displacementFraction(at: 0.1))
  }
}
