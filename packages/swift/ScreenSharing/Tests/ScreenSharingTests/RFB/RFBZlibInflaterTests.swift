import Foundation
import Testing
@testable import ScreenSharing

/// The single zlib stream ZRLE runs over: what it does with input that arrives
/// in pieces, output that outgrows its scratch buffer, and bytes that are not
/// zlib at all.
struct RFBZlibInflaterTests {
  private static let sentence = Array("the quick brown fox jumps over the lazy dog, twice".utf8)

  @Test func aSyncFlushedChunkIsReadableImmediately() throws {
    let deflater = try RFBZlibDeflater()
    let inflater = try RFBZlibInflater()
    #expect(try inflater.inflate(deflater.deflate(Self.sentence)) == Self.sentence)
  }

  /// Each sync-flushed chunk continues the stream rather than starting a new
  /// one, which is what lets ZRLE rectangles share a single inflater.
  @Test func laterChunksContinueTheSameStream() throws {
    let deflater = try RFBZlibDeflater()
    let inflater = try RFBZlibInflater()
    var produced: [UInt8] = []
    for round in 0..<8 {
      let payload = Self.sentence + [UInt8(round)]
      produced += try inflater.inflate(deflater.deflate(payload))
      #expect(produced.suffix(payload.count) == payload[...])
    }
    #expect(produced.count == (Self.sentence.count + 1) * 8)
    // The zlib header appears once, at the very start of the stream.
    #expect(Array(try RFBZlibDeflater().deflate(Self.sentence).prefix(2)) == [0x78, 0x9c])
  }

  /// A chunk split anywhere still inflates to the same bytes: the reader may
  /// hand over as little as one byte at a time.
  @Test func compressedInputMayArriveOneByteAtATime() throws {
    let deflater = try RFBZlibDeflater()
    let compressed = try deflater.deflate(Self.sentence) + deflater.deflate(Self.sentence)
    let inflater = try RFBZlibInflater()
    var produced: [UInt8] = []
    for byte in compressed { produced += try inflater.inflate([byte]) }
    #expect(produced == Self.sentence + Self.sentence)
  }

  @Test(arguments: [1, 2, 3, 17, 1024])
  func everySplitOfTheStreamGivesTheSameBytes(_ chunk: Int) throws {
    let deflater = try RFBZlibDeflater()
    let compressed = try deflater.deflate(Self.sentence)
    let inflater = try RFBZlibInflater()
    var produced: [UInt8] = []
    for start in stride(from: 0, to: compressed.count, by: chunk) {
      produced += try inflater.inflate(Array(compressed[start..<min(start + chunk, compressed.count)]))
    }
    #expect(produced == Self.sentence)
  }

  /// The scratch buffer is 64 KiB, so a megabyte of output has to be drained
  /// over many passes before the call returns.
  @Test func outputLargerThanTheScratchBufferIsReturnedWhole() throws {
    let payload = (0..<(1 << 20)).map { UInt8($0 % 251) }
    let compressed = try RFBZlibDeflater().deflate(payload)
    #expect(compressed.count < payload.count)
    #expect(try RFBZlibInflater().inflate(compressed) == payload)
  }

  @Test func nothingInIsNothingOut() throws {
    let inflater = try RFBZlibInflater()
    #expect(try inflater.inflate([]) == [])
    // And the stream is still usable afterwards.
    #expect(try inflater.inflate(RFBZlibDeflater().deflate(Self.sentence)) == Self.sentence)
  }

  /// Compressing nothing still emits a sync-flush marker, which inflates to
  /// nothing without ending or corrupting the stream.
  @Test func anEmptySyncFlushCarriesNoPixels() throws {
    let deflater = try RFBZlibDeflater()
    let inflater = try RFBZlibInflater()
    #expect(try inflater.inflate(deflater.deflate([])) == [])
    #expect(try inflater.inflate(deflater.deflate(Self.sentence)) == Self.sentence)
  }

  @Test func bytesThatAreNotZlibAreMalformed() throws {
    // 0x1f 0x8b is gzip, not the zlib wrapper zlib's inflateInit expects.
    #expect(throws: RFBError.malformed("zlib error -3")) { try RFBZlibInflater().inflate([0x1f, 0x8b, 0x08, 0x00]) }
    #expect(throws: RFBError.malformed("zlib error -3")) {
      try RFBZlibInflater().inflate([UInt8](repeating: 0xff, count: 64))
    }
  }

  /// A stream that starts correctly and is then corrupted fails on the bad
  /// bytes, not silently on the good ones.
  @Test func corruptionAfterAValidHeaderIsMalformed() throws {
    var compressed = try RFBZlibDeflater().deflate(Self.sentence)
    compressed.replaceSubrange(6..<compressed.count, with: [UInt8](repeating: 0xa5, count: compressed.count - 6))
    #expect(throws: RFBError.self) { try RFBZlibInflater().inflate(compressed) }
  }

  @Test func deflatingIsLosslessForEveryByteValue() throws {
    let payload = (0...255).map(UInt8.init)
    #expect(try RFBZlibInflater().inflate(RFBZlibDeflater().deflate(payload)) == payload)
  }
}
