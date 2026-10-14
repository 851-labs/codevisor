import Foundation
import os

public final class ScreenSharingAudioJitterBuffer: @unchecked Sendable {
  public let slackFrames: Int
  public let drainFrames: Int
  public let capacityFrames: Int
  private let lock = OSAllocatedUnfairLock()
  private let left: UnsafeMutablePointer<Float>
  private let right: UnsafeMutablePointer<Float>
  private var target: Int
  private var readIndex = 0
  private var writeIndex = 0
  private var nextSequence: UInt32?
  private var playing = false
  private var underrunCount = 0
  private var lostCount = 0
  private var droppedCount = 0

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

  public func push(
    sequence: UInt32, left newLeft: UnsafePointer<Float>, right newRight: UnsafePointer<Float>, frames: Int
  ) {
    guard frames > 0 else { return }
    lock.withLockUnchecked {
      if let expected = nextSequence {
        let ahead = sequence &- expected
        guard ahead < UInt32.max / 2 else { return }
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

  public func pull(frames: Int, left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>?)
  {
    guard frames > 0 else { return }
    let copied: Int = lock.withLockUnchecked {
      if !playing {
        guard writeIndex - readIndex >= target else { return 0 }
        playing = true
      }
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

  private func write(_ sourceLeft: UnsafePointer<Float>, _ sourceRight: UnsafePointer<Float>, frames: Int) {
    var remaining = frames
    var offset = 0
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
