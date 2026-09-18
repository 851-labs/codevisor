import Foundation
import Testing
@testable import ScreenSharing

struct RFBFramebufferTests {
  @Test func rawFillWritesRowsAtTheStride() throws {
    let framebuffer = try RFBFramebuffer(width: 4, height: 3)
    try framebuffer.fillRaw(RFBRectangle(x: 1, y: 1, width: 2, height: 2), from: Array(1...16))
    #expect(framebuffer.pixel(x: 1, y: 1) == (1, 2, 3))
    #expect(framebuffer.pixel(x: 2, y: 1) == (5, 6, 7))
    #expect(framebuffer.pixel(x: 1, y: 2) == (9, 10, 11))
    #expect(framebuffer.pixel(x: 0, y: 0) == (0, 0, 0))
    #expect(framebuffer.pixel(x: 3, y: 2) == (0, 0, 0))
    #expect(throws: RFBError.self) {
      try framebuffer.fillRaw(RFBRectangle(x: 3, y: 0, width: 2, height: 1), from: Array(1...8))
    }
    #expect(throws: RFBError.self) { try framebuffer.fillRaw(RFBRectangle(x: 0, y: 0, width: 1, height: 1), from: [1]) }
  }

  @Test func overlappingCopiesInBothDirections() throws {
    let framebuffer = try RFBFramebuffer(width: 2, height: 4)
    for y in 0..<4 {
      try framebuffer.fill(RFBRectangle(x: 0, y: y, width: 2, height: 1), blue: UInt8(y), green: 0, red: 0)
    }
    try framebuffer.copy(RFBRectangle(x: 0, y: 1, width: 2, height: 3), fromX: 0, fromY: 0)  // down
    #expect((0..<4).map { framebuffer.pixel(x: 0, y: $0).blue } == [0, 0, 1, 2])
    try framebuffer.copy(RFBRectangle(x: 0, y: 0, width: 2, height: 3), fromX: 0, fromY: 1)  // up
    #expect((0..<4).map { framebuffer.pixel(x: 1, y: $0).blue } == [0, 1, 2, 2])
    #expect(throws: RFBError.self) {
      try framebuffer.copy(RFBRectangle(x: 0, y: 0, width: 2, height: 1), fromX: 1, fromY: 0)
    }
  }

  @Test func resizeReplacesTheContentAndBoundsAreEnforced() throws {
    let framebuffer = try RFBFramebuffer(width: 2, height: 2)
    try framebuffer.fill(RFBRectangle(x: 0, y: 0, width: 2, height: 2), blue: 9, green: 9, red: 9)
    try framebuffer.resize(width: 3, height: 1)
    #expect(framebuffer.pixels.count == 12)
    #expect(framebuffer.pixel(x: 2, y: 0) == (0, 0, 0))
    #expect(throws: RFBError.self) { try framebuffer.resize(width: 0, height: 1) }
    #expect(throws: RFBError.self) { try RFBFramebuffer(width: 1, height: RFBFramebuffer.maximumDimension + 1) }
  }
}
