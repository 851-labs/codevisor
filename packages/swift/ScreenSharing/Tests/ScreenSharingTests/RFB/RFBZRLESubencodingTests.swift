import Foundation
import Testing
@testable import ScreenSharing

struct RFBZRLESubencodingTests {
  private func cpixel(_ blue: UInt8) -> [UInt8] { [blue, 0, 0] }

  private func decode(
    _ bytes: [UInt8], rect: RFBRectangle, width: Int, height: Int
  ) throws -> RFBFramebuffer {
    let framebuffer = try RFBFramebuffer(width: width, height: height)
    try RFBZRLEDecoder.decode(bytes, rect: rect, into: framebuffer)
    return framebuffer
  }

  private func decode(_ bytes: [UInt8], width: Int, height: Int) throws -> RFBFramebuffer {
    try decode(bytes, rect: RFBRectangle(x: 0, y: 0, width: width, height: height), width: width, height: height)
  }

  @Test func rawTilesAreRowMajorAndOpaque() throws {
    let framebuffer = try decode([0] + (1...6).flatMap { cpixel(UInt8($0)) }, width: 3, height: 2)
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 0).blue } == [1, 2, 3])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 1).blue } == [4, 5, 6])
    #expect(framebuffer.pixels[3] == 0xff)
  }

  @Test func aSolidTileIsOneCPixelForTheWholeTile() throws {
    let framebuffer = try decode([1] + cpixel(42), width: 64, height: 64)
    #expect(framebuffer.pixel(x: 0, y: 0) == (42, 0, 0))
    #expect(framebuffer.pixel(x: 63, y: 63) == (42, 0, 0))
  }

  @Test(arguments: [(2, 1), (3, 2), (4, 2), (5, 4), (8, 4), (16, 4)])
  func packedPaletteBitWidthsFollowThePaletteSize(_ colours: Int, _ bits: Int) throws {
    let palette = (1...colours).flatMap { cpixel(UInt8($0)) }
    var packed: [UInt8] = []
    var byte: UInt8 = 0
    var used = 0
    for index in 0..<colours {
      byte |= UInt8(index) << UInt8(8 - bits - used)
      used += bits
      if used == 8 {
        packed.append(byte)
        byte = 0
        used = 0
      }
    }
    if used > 0 { packed.append(byte) }
    let framebuffer = try decode([UInt8(colours)] + palette + packed, width: colours, height: 1)
    #expect((0..<colours).map { framebuffer.pixel(x: $0, y: 0).blue } == (1...colours).map(UInt8.init))
  }

  @Test func eachPackedPaletteRowStartsOnAFreshByte() throws {
    let framebuffer = try decode(
      [2] + cpixel(1) + cpixel(2) + [0b1000_0000, 0b0110_0000, 0b0010_0000], width: 3, height: 3)
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 0).blue } == [2, 1, 1])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 1).blue } == [1, 2, 2])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 2).blue } == [1, 1, 2])
  }

  @Test func aPackedIndexOutsideThePaletteIsMalformed() throws {
    #expect(throws: RFBError.malformed("ZRLE palette index")) {
      try decode([3] + cpixel(1) + cpixel(2) + cpixel(3) + [0b1100_0000], width: 1, height: 1)
    }
  }

  @Test func plainRunLengthEncodingCrossesRowsWithinATile() throws {
    let framebuffer = try decode([128] + cpixel(9) + [4] + cpixel(8) + [0], width: 3, height: 2)
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 0).blue } == [9, 9, 9])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 1).blue } == [9, 9, 8])
  }

  @Test func runLengthsContinueThroughEveryTwoHundredAndFiftyFive() throws {
    let framebuffer = try decode([128] + cpixel(3) + [255, 255, 0] + cpixel(4) + [0], width: 64, height: 8)
    #expect(framebuffer.pixel(x: 62, y: 7).blue == 3)
    #expect(framebuffer.pixel(x: 63, y: 7).blue == 4)
  }

  @Test func paletteRunLengthEncodingMixesRunsAndSinglePixels() throws {
    let framebuffer = try decode(
      [131] + cpixel(1) + cpixel(2) + cpixel(3) + [0x82, 2, 0x00, 0x81, 1], width: 6, height: 1)
    #expect((0..<6).map { framebuffer.pixel(x: $0, y: 0).blue } == [3, 3, 3, 1, 2, 2])
  }

  @Test func aPaletteRunIndexOutsideThePaletteIsMalformed() throws {
    #expect(throws: RFBError.malformed("ZRLE palette index")) {
      try decode([130] + cpixel(1) + cpixel(2) + [0x83, 0], width: 4, height: 1)
    }
  }

  @Test(arguments: [UInt8(17), 18, 100, 127, 129])
  func reservedSubencodingsAreMalformed(_ subencoding: UInt8) throws {
    #expect(throws: RFBError.malformed("ZRLE subencoding \(subencoding)")) {
      try decode([subencoding] + cpixel(0) + cpixel(0), width: 1, height: 1)
    }
  }

  @Test func aRunPastTheEndOfTheTileIsMalformed() throws {
    #expect(throws: RFBError.malformed("ZRLE run overflow")) {
      try decode([128] + cpixel(1) + [9], width: 4, height: 1)
    }
    #expect(throws: RFBError.malformed("ZRLE run overflow")) {
      try decode([130] + cpixel(1) + cpixel(2) + [0x80, 9], width: 4, height: 1)
    }
  }

  @Test func partialTilesOnBothAxes() throws {
    let data = [[1] + cpixel(11), [1] + cpixel(12), [1] + cpixel(13), [1] + cpixel(14)].flatMap { $0 }
    let framebuffer = try decode(data, width: 70, height: 70)
    #expect(framebuffer.pixel(x: 63, y: 63).blue == 11)
    #expect(framebuffer.pixel(x: 64, y: 63).blue == 12)
    #expect(framebuffer.pixel(x: 63, y: 64).blue == 13)
    #expect(framebuffer.pixel(x: 69, y: 69).blue == 14)
  }

  @Test func tilesAreRelativeToTheRectangleNotTheFramebuffer() throws {
    let rect = RFBRectangle(x: 10, y: 20, width: 70, height: 70)
    let data = [[1] + cpixel(1), [1] + cpixel(2), [1] + cpixel(3), [1] + cpixel(4)].flatMap { $0 }
    let framebuffer = try decode(data, rect: rect, width: 100, height: 100)
    #expect(framebuffer.pixel(x: 10, y: 20).blue == 1)
    #expect(framebuffer.pixel(x: 73, y: 83).blue == 1)
    #expect(framebuffer.pixel(x: 74, y: 83).blue == 2)
    #expect(framebuffer.pixel(x: 73, y: 84).blue == 3)
    #expect(framebuffer.pixel(x: 79, y: 89).blue == 4)
    #expect(framebuffer.pixel(x: 9, y: 20) == (0, 0, 0))
    #expect(framebuffer.pixel(x: 80, y: 20) == (0, 0, 0))
    #expect(framebuffer.pixel(x: 10, y: 90) == (0, 0, 0))
  }

  @Test func aPartialRawTileCarriesOnlyItsOwnPixels() throws {
    let wide: [UInt8] = (1...(64 * 2)).flatMap { cpixel(UInt8($0 % 251)) }
    let narrow: [UInt8] = (1...(6 * 2)).flatMap { cpixel(UInt8(200 + $0)) }
    let tile: [UInt8] = [0] + wide + [0] + narrow
    let framebuffer = try decode(tile, width: 70, height: 2)
    #expect(framebuffer.pixel(x: 0, y: 0).blue == 1)
    #expect(framebuffer.pixel(x: 63, y: 0).blue == 64)
    #expect(framebuffer.pixel(x: 0, y: 1).blue == 65)
    #expect(framebuffer.pixel(x: 64, y: 0).blue == 201)
    #expect(framebuffer.pixel(x: 69, y: 0).blue == 206)
    #expect(framebuffer.pixel(x: 64, y: 1).blue == 207)
    #expect(throws: RFBError.malformed("ZRLE truncated")) { try decode(Array(tile.dropLast()), width: 70, height: 2) }
    #expect(throws: RFBError.malformed("ZRLE trailing bytes")) { try decode(tile + [0], width: 70, height: 2) }
  }

  @Test func aRectangleOutsideTheFramebufferIsRefusedBeforeDecoding() throws {
    #expect(throws: RFBError.self) {
      try decode([1] + cpixel(1), rect: RFBRectangle(x: 0, y: 0, width: 5, height: 5), width: 4, height: 4)
    }
  }
}
