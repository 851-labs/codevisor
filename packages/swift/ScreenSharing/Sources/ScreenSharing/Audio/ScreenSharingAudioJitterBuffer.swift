import Foundation

/// The viewer's buffer between arriving packets and the audio device: interleaved stereo
/// samples. It fills to `targetFrames` before playing (so network jitter doesn't click), covers a
/// lost packet with silence, drops what arrives late or twice, catches up gently when it runs
/// more than `drainFrames` past the target (bursts after a refill would otherwise pile up and the
/// sound fall behind the picture), and drops the oldest audio outright past `slackFrames`. Pure
/// state; the player guards it with a lock.
public struct ScreenSharingAudioJitterBuffer: Sendable {
  public var targetFrames: Int
  public let slackFrames: Int
  public let drainFrames: Int
  private var samples: [Float] = []
  private var nextSequence: UInt32?
  private var playing = false
  public private(set) var underruns = 0
  public private(set) var lostPackets = 0
  public private(set) var droppedFrames = 0

  public init(targetFrames: Int, slackFrames: Int = 7_200, drainFrames: Int = 1_200) {
    self.targetFrames = targetFrames; self.slackFrames = slackFrames; self.drainFrames = drainFrames
  }

  public var bufferedFrames: Int { samples.count / ScreenSharingAudioFormat.channels }

  /// One decoded packet (interleaved stereo).
  public mutating func push(sequence: UInt32, samples packet: [Float]) {
    if let expected = nextSequence {
      let ahead = sequence &- expected
      // Behind (late or a duplicate): its moment has passed.
      guard ahead < UInt32.max / 2 else { return }
      // A short gap is covered with silence; a long one (a pause) just restarts the stream.
      if ahead > 0, ahead <= 5 {
        lostPackets += Int(ahead)
        samples += [Float](repeating: 0, count: Int(ahead) * packet.count)
      }
    }
    nextSequence = sequence &+ 1
    samples += packet
    let excess = bufferedFrames - (targetFrames + slackFrames)
    if excess > 0 {
      samples.removeFirst(excess * ScreenSharingAudioFormat.channels)
      droppedFrames += excess
    }
  }

  /// `frames` frames for the device, silence while (re)filling.
  public mutating func pull(frames: Int) -> [Float] {
    if !playing {
      guard bufferedFrames >= targetFrames else { return [Float](repeating: 0, count: frames * 2) }
      playing = true
    }
    // Over the target: play up to a tenth faster (skip that much) until back near it.
    let over = bufferedFrames - frames - targetFrames - drainFrames
    if over > 0 {
      let skip = min(over, max(1, frames / 10))
      samples.removeFirst(skip * ScreenSharingAudioFormat.channels)
      droppedFrames += skip
    }
    let wanted = frames * ScreenSharingAudioFormat.channels
    guard samples.count >= wanted else {
      underruns += 1
      playing = false
      var partial = samples
      samples.removeAll(keepingCapacity: true)
      partial += [Float](repeating: 0, count: wanted - partial.count)
      return partial
    }
    let out = Array(samples.prefix(wanted))
    samples.removeFirst(wanted)
    return out
  }
}
