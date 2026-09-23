import Foundation
import Testing
@testable import ScreenSharing

/// The buffered big-endian reader every message parser sits on: what it makes
/// of the transport's chunking, and where a short read turns into which error.
struct RFBInputStreamTests {
  @Test func integersAreBigEndianRegardlessOfChunking() async throws {
    let bytes: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0xff, 0xff, 0xff, 0xff]
    for chunk in 1...13 {
      let stream = RFBInputStream(transport: ScriptedTransport(bytes, chunk: chunk))
      #expect(try await stream.u8() == 0x12)
      #expect(try await stream.u16() == 0x3456)
      #expect(try await stream.u32() == 0x789a_bcde)
      #expect(try await stream.bytes(1) == [0xf0])
      #expect(try await stream.s32() == -1)
    }
  }

  @Test func signedThirtyTwoBitValuesWrapAtTheSignBit() async throws {
    let stream = RFBInputStream(
      transport: ScriptedTransport(u32(0x8000_0000) + u32(0x7fff_ffff) + u32(UInt32(bitPattern: -223)), chunk: 3))
    #expect(try await stream.s32() == Int32.min)
    #expect(try await stream.s32() == Int32.max)
    #expect(try await stream.s32() == -223)
  }

  /// The chunk size is the transport's business: the same reads over the same
  /// bytes give the same values however the bytes arrive, including one at a
  /// time and all at once.
  @Test func theTransportsFramingNeverShowsThrough() async throws {
    let payload = (0..<1000).map { UInt8($0 % 251) }
    for chunk in [1, 2, 3, 7, 64, 999, 1000, 4096] {
      let stream = RFBInputStream(transport: ScriptedTransport(payload, chunk: chunk), chunk: 8)
      var read: [UInt8] = []
      // Deliberately uneven reads, so the internal compaction runs mid-stream.
      for size in [1, 300, 7, 0, 92, 600] { read += try await stream.bytes(size) }
      #expect(read == payload)
    }
  }

  @Test func aZeroLengthReadConsumesNothingEvenAtTheEnd() async throws {
    let stream = RFBInputStream(transport: ScriptedTransport([], chunk: 1))
    #expect(try await stream.bytes(0) == [])
    await #expect(throws: RFBError.connectionClosed) { try await stream.u8() }
  }

  @Test func aNegativeLengthIsMalformedRatherThanATrap() async throws {
    let stream = RFBInputStream(transport: ScriptedTransport([1, 2, 3], chunk: 1))
    await #expect(throws: RFBError.malformed("negative length")) { try await stream.bytes(-1) }
    await #expect(throws: RFBError.malformed("negative length")) { try await stream.skip(-8) }
  }

  /// A field that is cut in half is a closed connection, not a short value.
  @Test func everyPartialFieldEndsTheConnection() async throws {
    await #expect(throws: RFBError.connectionClosed) {
      _ = try await RFBInputStream(transport: ScriptedTransport([], chunk: 1)).u8()
    }
    await #expect(throws: RFBError.connectionClosed) {
      _ = try await RFBInputStream(transport: ScriptedTransport([1], chunk: 1)).u16()
    }
    for available in 0..<4 {
      let stream = RFBInputStream(transport: ScriptedTransport(Array(repeating: 9, count: available), chunk: 1))
      await #expect(throws: RFBError.connectionClosed, "\(available) of 4 bytes") { _ = try await stream.u32() }
    }
    let short = RFBInputStream(transport: ScriptedTransport([1, 2, 3], chunk: 2))
    await #expect(throws: RFBError.connectionClosed) { _ = try await short.bytes(4) }
  }

  /// The bytes already buffered before the peer went away are lost with it:
  /// the stream has no resynchronisation, so the error is terminal.
  @Test func aClosedStreamKeepsFailing() async throws {
    let stream = RFBInputStream(transport: ScriptedTransport([1, 2], chunk: 2))
    #expect(try await stream.u16() == 0x0102)
    await #expect(throws: RFBError.connectionClosed) { _ = try await stream.u8() }
    await #expect(throws: RFBError.connectionClosed) { _ = try await stream.u8() }
  }

  @Test func skipDiscardsExactlyTheRequestedBytes() async throws {
    let stream = RFBInputStream(transport: ScriptedTransport(Array(0..<20), chunk: 3))
    try await stream.skip(0)
    try await stream.skip(17)
    #expect(try await stream.bytes(3) == [17, 18, 19])
  }

  @Test func theWriterIsBigEndianToo() {
    var writer = RFBByteWriter()
    writer.u8(0xab)
    writer.u16(0x1234)
    writer.u32(0xdead_beef)
    writer.s32(-2)
    writer.pad(3)
    writer.append([7, 7])
    #expect(writer.bytes == [UInt8](hex: "ab 1234 deadbeef fffffffe 000000 0707"))
  }

  /// 851-2320: a 1 MiB rectangle read from 64 KiB transport chunks moves each
  /// byte at most once on compaction.
  @Test func compactionMovesEachByteAtMostOnce() async throws {
    let payload = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
    let stream = RFBInputStream(transport: ScriptedTransport(payload, chunk: 1 << 16), chunk: 1 << 16)
    var read: [UInt8] = []
    while read.count < payload.count { read += try await stream.bytes(min(40_000, payload.count - read.count)) }
    #expect(read == payload)
    #expect(stream.bytesMoved <= payload.count)
  }
}
