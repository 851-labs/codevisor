import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Transcript send attachment geometry")
struct TranscriptSendAttachmentGeometryTests {
  @Test("Sent attachments line up in composer order, the last one at the trailing edge")
  func stripIsTrailingAnchoredInOrder() {
    let frames = TranscriptSendAttachmentGeometry.strip(
      sizes: [CGSize(width: 56, height: 56), CGSize(width: 120, height: 40)],
      trailing: 400, top: 100, spacing: 8)

    #expect(
      frames == [
        CGRect(x: 216, y: 100, width: 56, height: 56),
        CGRect(x: 280, y: 100, width: 120, height: 40),
      ])
  }

  @Test("A portrait photo fills a square chip by overflowing its height and fits by narrowing its width")
  func portraitPhotoFillsAndFits() {
    let square = CGSize(width: 56, height: 56)

    #expect(TranscriptSendAttachmentGeometry.filling(aspectRatio: 0.5, in: square) == CGSize(width: 56, height: 112))
    #expect(TranscriptSendAttachmentGeometry.fitting(aspectRatio: 0.5, in: square) == CGSize(width: 28, height: 56))
  }
}
