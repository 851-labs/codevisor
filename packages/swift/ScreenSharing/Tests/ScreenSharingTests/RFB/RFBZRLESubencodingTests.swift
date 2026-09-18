import Foundation
import Testing
@testable import ScreenSharing

/// ZRLE subencodings (RFC 6143 §7.7.6) one at a time, and how tiles are laid
/// over a rectangle that does not divide by 64.
struct RFBZRLESubencodingTests {
  /// A CPIXEL in this client's format: three bytes, blue first.
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
    #expect(framebuffer.pixels[3] == 0xff)  // alpha is written, never left at zero
  }

  @Test func aSolidTileIsOneCPixelForTheWholeTile() throws {
    let framebuffer = try decode([1] + cpixel(42), width: 64, height: 64)
    #expect(framebuffer.pixel(x: 0, y: 0) == (42, 0, 0))
    #expect(framebuffer.pixel(x: 63, y: 63) == (42, 0, 0))
  }

  /// Palette size decides the bit width: 2 colours take one bit, 3–4 take two,
  /// 5–16 take four, and every row restarts on a byte boundary.
  @Test(arguments: [(2, 1), (3, 2), (4, 2), (5, 4), (8, 4), (16, 4)])
  func packedPaletteBitWidthsFollowThePaletteSize(_ colours: Int, _ bits: Int) throws {
    let palette = (1...colours).flatMap { cpixel(UInt8($0)) }
    // One row of `colours` pixels indexing the palette in order, packed `bits` wide.
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
    // 2 colours, 1 bit, 3 pixels per row: five bits of every byte are padding.
    let framebuffer = try decode(
      [2] + cpixel(1) + cpixel(2) + [0b1000_0000, 0b0110_0000, 0b0010_0000], width: 3, height: 3)
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 0).blue } == [2, 1, 1])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 1).blue } == [1, 2, 2])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 2).blue } == [1, 1, 2])
  }

  @Test func aPackedIndexOutsideThePaletteIsMalformed() throws {
    // 3 colours take two bits, so index 3 is representable but not in the palette.
    #expect(throws: RFBError.malformed("ZRLE palette index")) {
      try decode([3] + cpixel(1) + cpixel(2) + cpixel(3) + [0b1100_0000], width: 1, height: 1)
    }
  }

  @Test func plainRunLengthEncodingCrossesRowsWithinATile() throws {
    // One run of 5 over a 3 x 2 tile plus a single pixel: runs are over the
    // tile's pixels in order, not over its rows.
    let framebuffer = try decode([128] + cpixel(9) + [4] + cpixel(8) + [0], width: 3, height: 2)
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 0).blue } == [9, 9, 9])
    #expect((0..<3).map { framebuffer.pixel(x: $0, y: 1).blue } == [9, 9, 8])
  }

  /// A run length is one plus a sum of bytes, and only a byte below 255 ends
  /// the sum: 255 always means "and keep adding".
  @Test func runLengthsContinueThroughEveryTwoHundredAndFiftyFive() throws {
    // 1 + 255 + 255 + 0 = 511 pixels of one colour, then a single pixel of another.
    let framebuffer = try decode([128] + cpixel(3) + [255, 255, 0] + cpixel(4) + [0], width: 64, height: 8)
    #expect(framebuffer.pixel(x: 62, y: 7).blue == 3)
    #expect(framebuffer.pixel(x: 63, y: 7).blue == 4)
  }

  @Test func paletteRunLengthEncodingMixesRunsAndSinglePixels() throws {
    // Palette of 3; the high bit means "a run length follows", so 0x82 with a
    // trailing 2 is three pixels of palette entry 2 and a bare 0x00 is one pixel.
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

  /// A rectangle whose sides are not multiples of 64 ends in partial tiles on
  /// both axes; each is decoded at its own width, so the last column of a
  /// six-wide tile is not read as the first of the next row.
  @Test func partialTilesOnBothAxes() throws {
    // 70 x 70: tiles of 64x64, 6x64, 64x6 and 6x6, each a different solid colour.
    let data = [[1] + cpixel(11), [1] + cpixel(12), [1] + cpixel(13), [1] + cpixel(14)].flatMap { $0 }
    let framebuffer = try decode(data, width: 70, height: 70)
    #expect(framebuffer.pixel(x: 63, y: 63).blue == 11)
    #expect(framebuffer.pixel(x: 64, y: 63).blue == 12)
    #expect(framebuffer.pixel(x: 63, y: 64).blue == 13)
    #expect(framebuffer.pixel(x: 69, y: 69).blue == 14)
  }

  /// Tiles are laid out from the rectangle's origin, not the framebuffer's,
  /// and nothing outside the rectangle is touched.
  @Test func tilesAreRelativeToTheRectangleNotTheFramebuffer() throws {
    let rect = RFBRectangle(x: 10, y: 20, width: 70, height: 70)
    let data = [[1] + cpixel(1), [1] + cpixel(2), [1] + cpixel(3), [1] + cpixel(4)].flatMap { $0 }
    let framebuffer = try decode(data, rect: rect, width: 100, height: 100)
    #expect(framebuffer.pixel(x: 10, y: 20).blue == 1)
    #expect(framebuffer.pixel(x: 73, y: 83).blue == 1)
    #expect(framebuffer.pixel(x: 74, y: 83).blue == 2)  // first column of the 6-wide tile
    #expect(framebuffer.pixel(x: 73, y: 84).blue == 3)
    #expect(framebuffer.pixel(x: 79, y: 89).blue == 4)  // last pixel of the rectangle
    #expect(framebuffer.pixel(x: 9, y: 20) == (0, 0, 0))
    #expect(framebuffer.pixel(x: 80, y: 20) == (0, 0, 0))
    #expect(framebuffer.pixel(x: 10, y: 90) == (0, 0, 0))
  }

  /// A raw partial tile carries exactly width x height CPIXELs; getting the
  /// count wrong is caught as trailing or missing bytes.
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
