import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingFrameMailboxOwnershipTests {
  private func makeBuffer(width: Int = 64) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, width, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return try #require(pixel)
  }

  @Test func mailboxTakeTransfersOwnershipAndClearReleases() throws {
    let mailbox = ScreenSharingFrameMailbox()
    weak var weakA: CVPixelBuffer?
    weak var weakB: CVPixelBuffer?
    try autoreleasepool {
      let a = try makeBuffer()
      weakA = a
      mailbox.put(.init(pixelBuffer: a, timestampNs: 1))
    }
    #expect(weakA != nil)
    try autoreleasepool {
      let b = try makeBuffer()
      weakB = b
      mailbox.put(.init(pixelBuffer: b, timestampNs: 2))
    }
    #expect(weakA == nil && weakB != nil)
    try autoreleasepool {
      let taken = try #require(mailbox.take())
      #expect(taken.pixelBuffer === weakB)
      #expect(mailbox.take() == nil)
    }
    #expect(weakB == nil)
    try autoreleasepool {
      let c = try makeBuffer()
      weakA = c
      mailbox.put(.init(pixelBuffer: c, timestampNs: 3))
    }
    mailbox.clear()
    #expect(weakA == nil)
  }

}
