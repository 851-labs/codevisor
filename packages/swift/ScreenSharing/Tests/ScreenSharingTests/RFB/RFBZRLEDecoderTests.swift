import Foundation
import Testing
@testable import ScreenSharing

struct RFBZRLEDecoderTests {
  private func decode(_ bytes: [UInt8], width: Int, height: Int) throws -> RFBFramebuffer {
    let framebuffer = try RFBFramebuffer(width: width, height: height)
    try RFBZRLEDecoder.decode(bytes, rect: RFBRectangle(x: 0, y: 0, width: width, height: height), into: framebuffer)
    return framebuffer
  }

  @Test func solidAndRawTiles() throws {
    let framebuffer = try decode([1, 10, 20, 30], width: 2, height: 2)
    #expect(framebuffer.pixel(x: 1, y: 1) == (10, 20, 30))
    let raw = try decode([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], width: 2, height: 2)
    #expect(raw.pixel(x: 1, y: 0) == (4, 5, 6))
    #expect(raw.pixel(x: 0, y: 1) == (7, 8, 9))
  }

  @Test func packedPalettesUseOneTwoAndFourBitsPerPixelRowByRow() throws {
    // 2 colours, 1 bit: row 0 = 1,0,1 ; row 1 = 0,1,1 (each row padded to a byte)
    let two = try decode([2, 0, 0, 0, 9, 9, 9, 0b1010_0000, 0b0110_0000], width: 3, height: 2)
    #expect((0..<3).map { two.pixel(x: $0, y: 0).blue } == [9, 0, 9])
    #expect((0..<3).map { two.pixel(x: $0, y: 1).blue } == [0, 9, 9])
    // 3 colours, 2 bits: indices 2,1,0
    let three = try decode([3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0b10_01_00_00], width: 3, height: 1)
    #expect((0..<3).map { three.pixel(x: $0, y: 0).blue } == [3, 2, 1])
    // 5 colours, 4 bits: indices 4,0,3
    var five: [UInt8] = [5]
    for colour in 1...5 { five += [UInt8(colour), 0, 0] }
    five += [0x40, 0x30]
    let decoded = try decode(five, width: 3, height: 1)
    #expect((0..<3).map { decoded.pixel(x: $0, y: 0).blue } == [5, 1, 4])
    #expect(throws: RFBError.self) { try decode([3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0b11_00_00_00], width: 1, height: 1) }
  }

  @Test func plainRunLengthEncoding() throws {
    // run of 3 (length byte 2), then run of 1 (length byte 0)
    let framebuffer = try decode([128, 1, 1, 1, 2, 2, 2, 2, 0], width: 4, height: 1)
    #expect((0..<4).map { framebuffer.pixel(x: $0, y: 0).blue } == [1, 1, 1, 2])
    // one 64 x 5 tile: a run continued with 255 (255 + 44 + 1 = 300 pixels), then 20 more
    let long = try decode([128, 7, 7, 7, 255, 44, 8, 8, 8, 19], width: 64, height: 5)
    #expect(long.pixel(x: 43, y: 4).blue == 7)
    #expect(long.pixel(x: 44, y: 4).blue == 8)
    #expect(long.pixel(x: 63, y: 4).blue == 8)
    #expect(throws: RFBError.self) { try decode([128, 1, 1, 1, 5], width: 4, height: 1) }  // overflow
  }

  @Test func paletteRunLengthEncoding() throws {
    // 2 palette entries: index 1 run of 3 (0x81, 2), index 0 single, index 1 single
    let framebuffer = try decode([130, 5, 5, 5, 6, 6, 6, 0x81, 2, 0, 1], width: 5, height: 1)
    #expect((0..<5).map { framebuffer.pixel(x: $0, y: 0).blue } == [6, 6, 6, 5, 6])
    // Index out of palette.
    #expect(throws: RFBError.self) { try decode([130, 5, 5, 5, 6, 6, 6, 2], width: 1, height: 1) }
  }

  @Test func rectanglesSpanTilesAndRejectBadInput() throws {
    // 100 x 1: two tiles (64 and 36 wide), both solid with different colours.
    let framebuffer = try decode([1, 1, 0, 0, 1, 2, 0, 0], width: 100, height: 1)
    #expect(framebuffer.pixel(x: 63, y: 0).blue == 1)
    #expect(framebuffer.pixel(x: 64, y: 0).blue == 2)
    #expect(throws: RFBError.malformed("ZRLE trailing bytes")) { try decode([1, 1, 0, 0, 0], width: 1, height: 1) }
    #expect(throws: RFBError.malformed("ZRLE truncated")) { try decode([1, 1, 0], width: 1, height: 1) }
    #expect(throws: RFBError.malformed("ZRLE subencoding 17")) { try decode([17], width: 1, height: 1) }
  }

  @Test func zlibRoundTripAcrossRectangles() throws {
    let deflater = try RFBZlibDeflater()
    let inflater = try RFBZlibInflater()
    let first = [UInt8](repeating: 1, count: 10_000), second: [UInt8] = Array(0..<255)
    #expect(try inflater.inflate(deflater.deflate(first)) == first)
    #expect(try inflater.inflate(deflater.deflate(second)) == second)
    #expect(throws: RFBError.self) { try RFBZlibInflater().inflate([0xff, 0xff, 0xff, 0xff]) }
  }
}
