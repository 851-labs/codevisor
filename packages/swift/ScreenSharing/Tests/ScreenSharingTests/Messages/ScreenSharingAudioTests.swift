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

  // MARK: Jitter buffer (frames are stereo: 2 samples each)

  static func packet(_ value: Float, frames: Int = 10) -> [Float] { [Float](repeating: value, count: frames * 2) }

  @Test func itFillsToTheTargetBeforePlaying() {
    var buffer = ScreenSharingAudioJitterBuffer(targetFrames: 20, slackFrames: 100)
    buffer.push(sequence: 0, samples: Self.packet(1))
    #expect(buffer.pull(frames: 5) == [Float](repeating: 0, count: 10), "10 of 20 frames: still filling")
    buffer.push(sequence: 1, samples: Self.packet(2))
    #expect(buffer.pull(frames: 5) == [Float](repeating: 1, count: 10))
    #expect(buffer.bufferedFrames == 15)
  }

  @Test func aLostPacketIsSilenceAndALateOneIsDropped() {
    var buffer = ScreenSharingAudioJitterBuffer(targetFrames: 1, slackFrames: 100)
    buffer.push(sequence: 0, samples: Self.packet(1))
    buffer.push(sequence: 2, samples: Self.packet(3))
    #expect(buffer.lostPackets == 1 && buffer.bufferedFrames == 30)
    buffer.push(sequence: 1, samples: Self.packet(2))
    #expect(buffer.bufferedFrames == 30, "packet 1 arrived after 2 and is dropped")
    #expect(buffer.pull(frames: 30) == Self.packet(1) + Self.packet(0) + Self.packet(3))
  }

  @Test func itDropsTheOldestWhenTooFarBehindAndRefillsAfterAnUnderrun() {
    var buffer = ScreenSharingAudioJitterBuffer(targetFrames: 10, slackFrames: 10)
    for sequence in 0..<3 { buffer.push(sequence: UInt32(sequence), samples: Self.packet(Float(sequence))) }
    #expect(buffer.bufferedFrames == 20 && buffer.droppedFrames == 10, "at most target + slack")
    #expect(buffer.pull(frames: 10) == Self.packet(1))
    _ = buffer.pull(frames: 15)
    #expect(buffer.underruns == 1)
    buffer.push(sequence: 3, samples: Self.packet(4, frames: 5))
    #expect(buffer.pull(frames: 5) == [Float](repeating: 0, count: 10), "refilling to the target again")
  }

  @Test func aBufferThatRanAheadCatchesUpATenthAtATime() {
    var buffer = ScreenSharingAudioJitterBuffer(targetFrames: 10, slackFrames: 1_000, drainFrames: 5)
    for sequence in 0..<10 { buffer.push(sequence: UInt32(sequence), samples: Self.packet(Float(sequence))) }
    #expect(buffer.bufferedFrames == 100)
    // 100 buffered, pulling 20: 65 over, so 2 frames (a tenth of 20) are skipped first.
    _ = buffer.pull(frames: 20)
    #expect(buffer.bufferedFrames == 78 && buffer.droppedFrames == 2)
    for _ in 0..<5 { _ = buffer.pull(frames: 10) }
    #expect(buffer.bufferedFrames == 23, "one frame skipped per pull of 10 while still over")
  }

  @Test func sequenceNumbersWrap() {
    var buffer = ScreenSharingAudioJitterBuffer(targetFrames: 1, slackFrames: 100)
    buffer.push(sequence: .max, samples: Self.packet(1))
    buffer.push(sequence: 0, samples: Self.packet(2))
    #expect(buffer.lostPackets == 0 && buffer.bufferedFrames == 20)
  }

  // MARK: Opus

  @Test func captureAudioBecomesStampedOpusPacketsThatDecode() throws {
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
    #expect(player.statistics.buffered > 960, "decoded to PCM (the first packet is shortened by Opus priming)")
  }
}
