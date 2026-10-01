import Foundation
import os

/// The viewer's buffer between arriving packets and the audio device: stereo frames in a
/// preallocated ring. It fills to `targetFrames` before playing (so network jitter doesn't click),
/// covers a lost packet with silence, drops what arrives late or twice, catches up gently when it
/// runs more than `drainFrames` past the target (bursts after a refill would otherwise pile up and
/// the sound fall behind the picture), and drops the oldest audio outright past `slackFrames`.
///
/// Real-time safe on the device's render thread: `pull` never allocates, and both sides do work
/// proportional only to the frames they move (dropping the oldest moves an index), under an
/// unfair lock (priority-donating) held for one bounded copy. The decoder pushes from its own
/// queue; the device pulls on its render thread.
public final class ScreenSharingAudioJitterBuffer: @unchecked Sendable {
  public let slackFrames: Int
  public let drainFrames: Int
  /// Frames the ring holds; pushes past it drop the oldest first.
  public let capacityFrames: Int
  private let lock = OSAllocatedUnfairLock()
  private let left: UnsafeMutablePointer<Float>
  private let right: UnsafeMutablePointer<Float>
  // Guarded by `lock`. Indices count frames ever written/read; the ring position is modulo capacity.
  private var target: Int
  private var readIndex = 0
  private var writeIndex = 0
  private var nextSequence: UInt32?
  private var playing = false
  private var underrunCount = 0
  private var lostCount = 0
  private var droppedCount = 0

  /// `capacityFrames` defaults to the longest target the session asks for (0.4 s), the slack and a
  /// burst of packets with a covered loss.
  public init(
    targetFrames: Int, slackFrames: Int = 7_200, drainFrames: Int = 1_200,
    capacityFrames: Int? = nil
  ) {
    self.slackFrames = slackFrames
    self.drainFrames = drainFrames
    let capacity =
      capacityFrames
      ?? (max(targetFrames, Int(0.4 * ScreenSharingAudioFormat.sampleRate)) + slackFrames + 8
        * ScreenSharingAudioFormat.framesPerPacket)
    self.capacityFrames = max(1, capacity)
    target = targetFrames
    left = .allocate(capacity: self.capacityFrames)
    right = .allocate(capacity: self.capacityFrames)
    left.initialize(repeating: 0, count: self.capacityFrames)
    right.initialize(repeating: 0, count: self.capacityFrames)
  }

  deinit {
    left.deallocate()
    right.deallocate()
  }

  public var targetFrames: Int {
    get { lock.withLockUnchecked { target } }
    set { lock.withLockUnchecked { target = newValue } }
  }

  public var bufferedFrames: Int { lock.withLockUnchecked { writeIndex - readIndex } }
  public var underruns: Int { lock.withLockUnchecked { underrunCount } }
  public var lostPackets: Int { lock.withLockUnchecked { lostCount } }
  public var droppedFrames: Int { lock.withLockUnchecked { droppedCount } }

  public struct Statistics: Sendable, Equatable {
    public var buffered: Int
    public var underruns: Int
    public var lost: Int
    public var dropped: Int
  }

  public var statistics: Statistics {
    lock.withLockUnchecked {
      Statistics(buffered: writeIndex - readIndex, underruns: underrunCount, lost: lostCount, dropped: droppedCount)
    }
  }

  /// One decoded packet, as planar channels of `frames` frames each.
  public func push(
    sequence: UInt32, left newLeft: UnsafePointer<Float>, right newRight: UnsafePointer<Float>, frames: Int
  ) {
    guard frames > 0 else { return }
    lock.withLockUnchecked {
      if let expected = nextSequence {
        let ahead = sequence &- expected
        // Behind (late or a duplicate): its moment has passed.
        guard ahead < UInt32.max / 2 else { return }
        // A short gap is covered with silence; a long one (a pause) just restarts the stream.
        if ahead > 0, ahead <= 5 {
          lostCount += Int(ahead)
          writeSilence(Int(ahead) * frames)
        }
      }
      nextSequence = sequence &+ 1
      write(newLeft, newRight, frames: frames)
      let excess = (writeIndex - readIndex) - (target + slackFrames)
      if excess > 0 { drop(excess) }
    }
  }

  /// `frames` frames for the device, silence while (re)filling. `right` may be nil for a mono device.
  public func pull(frames: Int, left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>?)
  {
    guard frames > 0 else { return }
    let copied: Int = lock.withLockUnchecked {
      if !playing {
        guard writeIndex - readIndex >= target else { return 0 }
        playing = true
      }
      // Over the target: play up to a tenth faster (skip that much) until back near it.
      let over = (writeIndex - readIndex) - frames - target - drainFrames
      if over > 0 { drop(min(over, max(1, frames / 10))) }
      let available = writeIndex - readIndex
      let count = min(frames, available)
      read(count, outLeft, outRight)
      if count < frames {
        underrunCount += 1
        playing = false
      }
      return count
    }
    if copied < frames {
      (outLeft + copied).update(repeating: 0, count: frames - copied)
      outRight.map { ($0 + copied).update(repeating: 0, count: frames - copied) }
    }
  }

  // MARK: Ring (callers hold `lock`)

  private func write(_ sourceLeft: UnsafePointer<Float>, _ sourceRight: UnsafePointer<Float>, frames: Int) {
    var remaining = frames
    var offset = 0
    // A packet larger than the ring keeps only its newest frames.
    if remaining > capacityFrames {
      droppedCount += remaining - capacityFrames
      offset = remaining - capacityFrames
      remaining = capacityFrames
    }
    makeRoom(for: remaining)
    while remaining > 0 {
      let position = writeIndex % capacityFrames
      let chunk = min(remaining, capacityFrames - position)
      (left + position).update(from: sourceLeft + offset, count: chunk)
      (right + position).update(from: sourceRight + offset, count: chunk)
      writeIndex += chunk; offset += chunk; remaining -= chunk
    }
  }

  private func writeSilence(_ frames: Int) {
    var remaining = min(frames, capacityFrames)
    droppedCount += frames - remaining
    makeRoom(for: remaining)
    while remaining > 0 {
      let position = writeIndex % capacityFrames
      let chunk = min(remaining, capacityFrames - position)
      (left + position).update(repeating: 0, count: chunk)
      (right + position).update(repeating: 0, count: chunk)
      writeIndex += chunk; remaining -= chunk
    }
  }

  private func read(_ frames: Int, _ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>?) {
    var remaining = frames
    var offset = 0
    while remaining > 0 {
      let position = readIndex % capacityFrames
      let chunk = min(remaining, capacityFrames - position)
      (outLeft + offset).update(from: left + position, count: chunk)
      outRight.map { ($0 + offset).update(from: right + position, count: chunk) }
      readIndex += chunk; offset += chunk; remaining -= chunk
    }
  }

  /// The ring is full: the oldest frames make way.
  private func makeRoom(for frames: Int) {
    let overflow = (writeIndex - readIndex) + frames - capacityFrames
    if overflow > 0 { drop(overflow) }
  }

  private func drop(_ frames: Int) {
    let count = min(frames, writeIndex - readIndex)
    readIndex += count
    droppedCount += count
  }
}
