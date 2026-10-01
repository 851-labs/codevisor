import AVFoundation
import Foundation
import Testing
@testable import ScreenSharing

/// The host's sound as its own stream (851-2379): wire format, the viewer's jitter buffer, and
/// Opus through AudioToolbox end to end (no audio device involved).
struct ScreenSharingAudioTests {
  @Test func everyMessageSurvivesTheWire() throws {
    let packet = ScreenSharingAudioPacket(
      sequence: .max, timestampNs: -5, frames: 960, payload: Data([1, 2, 3, 250]))
    for message: ScreenSharingAudioMessage in [.subscribe, .unsubscribe, .packet(packet)] {
      #expect(try ScreenSharingAudioMessage.decode(message.encoded()) == message)
    }
  }

  @Test func otherVersionsKindsAndSizesAreRefused() {
    for bytes: [UInt8] in [[2, 0], [1, 9], [1], [1, 2, 0, 0], [1, 0, 7]] {
      #expect(throws: ScreenSharingError.self) { try ScreenSharingAudioMessage.decode(Data(bytes)) }
    }
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingAudioMessage.decode(Data([1, 2]) + Data(count: ScreenSharingAudioMessage.maximumBytes))
    }
  }

  // MARK: Jitter buffer (frames are stereo; expectations are interleaved: 2 samples each)

  static func packet(_ value: Float, frames: Int = 10) -> [Float] { [Float](repeating: value, count: frames * 2) }

  /// Pushes a packet whose every sample is `value` (and `-value` on the right when `signed`).
  static func push(
    _ buffer: ScreenSharingAudioJitterBuffer, _ sequence: UInt32, _ value: Float, frames: Int = 10,
    signed: Bool = false
  ) {
    let left = [Float](repeating: value, count: frames)
    let right = [Float](repeating: signed ? -value : value, count: frames)
    left.withUnsafeBufferPointer { left in
      right.withUnsafeBufferPointer { right in
        buffer.push(sequence: sequence, left: left.baseAddress!, right: right.baseAddress!, frames: frames)
      }
    }
  }

  /// Pulls into planar device buffers prefilled with NaN, returned interleaved.
  static func pull(_ buffer: ScreenSharingAudioJitterBuffer, frames: Int) -> [Float] {
    var left = [Float](repeating: .nan, count: frames)
    var right = [Float](repeating: .nan, count: frames)
    left.withUnsafeMutableBufferPointer { left in
      right.withUnsafeMutableBufferPointer { right in
        buffer.pull(frames: frames, left: left.baseAddress!, right: right.baseAddress!)
      }
    }
    return zip(left, right).flatMap { [$0, $1] }
  }

  @Test func itFillsToTheTargetBeforePlaying() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 20, slackFrames: 100)
    Self.push(buffer, 0, 1)
    #expect(Self.pull(buffer, frames: 5) == [Float](repeating: 0, count: 10), "10 of 20 frames: still filling")
    Self.push(buffer, 1, 2)
    #expect(Self.pull(buffer, frames: 5) == [Float](repeating: 1, count: 10))
    #expect(buffer.bufferedFrames == 15)
  }

  @Test func aLostPacketIsSilenceAndALateOneIsDropped() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 1, slackFrames: 100)
    Self.push(buffer, 0, 1)
    Self.push(buffer, 2, 3)
    #expect(buffer.lostPackets == 1 && buffer.bufferedFrames == 30)
    Self.push(buffer, 1, 2)
    #expect(buffer.bufferedFrames == 30, "packet 1 arrived after 2 and is dropped")
    #expect(Self.pull(buffer, frames: 30) == Self.packet(1) + Self.packet(0) + Self.packet(3))
  }

  @Test func itDropsTheOldestWhenTooFarBehindAndRefillsAfterAnUnderrun() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 10, slackFrames: 10)
    for sequence in 0..<3 { Self.push(buffer, UInt32(sequence), Float(sequence)) }
    #expect(buffer.bufferedFrames == 20 && buffer.droppedFrames == 10, "at most target + slack")
    #expect(Self.pull(buffer, frames: 10) == Self.packet(1))
    #expect(Self.pull(buffer, frames: 15) == Self.packet(2) + Self.packet(0, frames: 5), "short: padded with silence")
    #expect(buffer.underruns == 1)
    Self.push(buffer, 3, 4, frames: 5)
    #expect(Self.pull(buffer, frames: 5) == [Float](repeating: 0, count: 10), "refilling to the target again")
  }

  @Test func aBufferThatRanAheadCatchesUpATenthAtATime() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 10, slackFrames: 1_000, drainFrames: 5)
    for sequence in 0..<10 { Self.push(buffer, UInt32(sequence), Float(sequence)) }
    #expect(buffer.bufferedFrames == 100)
    // 100 buffered, pulling 20: 65 over, so 2 frames (a tenth of 20) are skipped first.
    _ = Self.pull(buffer, frames: 20)
    #expect(buffer.bufferedFrames == 78 && buffer.droppedFrames == 2)
    for _ in 0..<5 { _ = Self.pull(buffer, frames: 10) }
    #expect(buffer.bufferedFrames == 23, "one frame skipped per pull of 10 while still over")
  }

  @Test func sequenceNumbersWrap() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 1, slackFrames: 100)
    Self.push(buffer, .max, 1)
    Self.push(buffer, 0, 2)
    #expect(buffer.lostPackets == 0 && buffer.bufferedFrames == 20)
  }

  /// The ring is allocated once: reads and writes that cross its end keep order and channels.
  @Test func theRingKeepsOrderAndChannelsAcrossItsEnd() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 1, slackFrames: 100, capacityFrames: 25)
    var expected: [Float] = []
    for sequence in 0..<12 {
      Self.push(buffer, UInt32(sequence), Float(sequence + 1), frames: 10, signed: true)
      let pulled = Self.pull(buffer, frames: 10)
      expected = (0..<10).flatMap { _ in [Float(sequence + 1), -Float(sequence + 1)] }
      #expect(pulled == expected, "packet \(sequence) after \(sequence * 10) frames through a 25-frame ring")
    }
    #expect(buffer.droppedFrames == 0 && buffer.underruns == 0)
  }

  /// A device that stops pulling (output not started yet, or stopped) never makes the buffer grow:
  /// past its capacity the oldest frames make way, as past the slack.
  @Test func aFullRingDropsTheOldestInsteadOfGrowing() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 5, slackFrames: 1_000, capacityFrames: 30)
    for sequence in 0..<5 { Self.push(buffer, UInt32(sequence), Float(sequence)) }
    #expect(buffer.bufferedFrames == 30 && buffer.droppedFrames == 20)
    #expect(Self.pull(buffer, frames: 30) == Self.packet(2) + Self.packet(3) + Self.packet(4))
  }

  /// A mono device gets the left channel and nothing is written past the frames asked for.
  @Test func aMonoDeviceGetsTheLeftChannel() {
    let buffer = ScreenSharingAudioJitterBuffer(targetFrames: 1, slackFrames: 100)
    Self.push(buffer, 0, 3, frames: 4, signed: true)
    var left = [Float](repeating: .nan, count: 6)
    left.withUnsafeMutableBufferPointer { buffer.pull(frames: 4, left: $0.baseAddress!, right: nil) }
    #expect(left.prefix(4) == [3, 3, 3, 3])
    #expect(left.suffix(2).allSatisfy { $0.isNaN })
  }

  // MARK: Opus

  @Test func captureAudioBecomesStampedOpusPacketsThatDecode() async throws {
    var packets: [ScreenSharingAudioPacket] = []
    let encoder = try ScreenSharingAudioEncoder { packets.append($0) }
    // 50 ms of a 44.1 kHz mono tone: resampled to 48 kHz stereo, two full 20 ms packets.
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205))
    input.frameLength = 2_205
    for index in 0..<2_205 { input.floatChannelData![0][index] = sin(Float(index) * 0.06) * 0.5 }
    encoder.append(input, timestampNs: 1_000_000_000)
    #expect(packets.count == 2)
    #expect(packets.map(\.sequence) == [0, 1])
    #expect(packets[0].timestampNs == 1_000_000_000 && packets[1].timestampNs == 1_020_000_000)
    #expect(packets.allSatisfy { $0.frames == 960 && !$0.payload.isEmpty && $0.payload.count < 1_500 })

    let player = try ScreenSharingAudioPlayer(targetDelay: 0.02)
    for packet in packets { player.receive(packet) }
    await player.decoded()
    #expect(player.statistics.buffered > 960, "decoded to PCM (the first packet is shortened by Opus priming)")
  }
}
