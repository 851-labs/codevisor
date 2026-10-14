import Foundation
import Testing
@testable import ScreenSharing

struct RFBZlibInflaterTests {
  private static let sentence = Array("the quick brown fox jumps over the lazy dog, twice".utf8)

  @Test func aSyncFlushedChunkIsReadableImmediately() throws {
    let deflater = try RFBZlibDeflater()
    let inflater = try RFBZlibInflater()
    #expect(try inflater.inflate(deflater.deflate(Self.sentence)) == Self.sentence)
  }

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
    #expect(Array(try RFBZlibDeflater().deflate(Self.sentence).prefix(2)) == [0x78, 0x9c])
  }

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

  @Test func outputLargerThanTheScratchBufferIsReturnedWhole() throws {
    let payload = (0..<(1 << 20)).map { UInt8($0 % 251) }
    let compressed = try RFBZlibDeflater().deflate(payload)
    #expect(compressed.count < payload.count)
    #expect(try RFBZlibInflater().inflate(compressed) == payload)
  }

  @Test func nothingInIsNothingOut() throws {
    let inflater = try RFBZlibInflater()
    #expect(try inflater.inflate([]) == [])
    #expect(try inflater.inflate(RFBZlibDeflater().deflate(Self.sentence)) == Self.sentence)
  }

  @Test func anEmptySyncFlushCarriesNoPixels() throws {
    let deflater = try RFBZlibDeflater()
    let inflater = try RFBZlibInflater()
    #expect(try inflater.inflate(deflater.deflate([])) == [])
    #expect(try inflater.inflate(deflater.deflate(Self.sentence)) == Self.sentence)
  }

  @Test func bytesThatAreNotZlibAreMalformed() throws {
    #expect(throws: RFBError.malformed("zlib error -3")) { try RFBZlibInflater().inflate([0x1f, 0x8b, 0x08, 0x00]) }
    #expect(throws: RFBError.malformed("zlib error -3")) {
      try RFBZlibInflater().inflate([UInt8](repeating: 0xff, count: 64))
    }
  }

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
