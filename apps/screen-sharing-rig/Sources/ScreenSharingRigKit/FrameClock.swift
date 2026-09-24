import Foundation

/// The cross-app frame clock (851-2358): a host page draws the frame number in
/// a strip of flat-coloured cells, any viewer's window is captured, and the
/// number read back says which host frame each viewer showed when.
///
/// The strip is `cellCount` cells in a row. Before it counts (and for a few
/// seconds after a click), every cell is orange (255, 128, 0), so a capture can
/// find it: a half-on green channel no data cell has, in sRGB or Display P3. Then each of the first `dataCells` cells
/// carries 3 bits of the frame number (red, green, blue each fully on or off,
/// most significant cell first), and the last two carry a 6-bit checksum
/// weighted by position: a strip caught half-updated (a VNC update that covered
/// part of it) fails it, 63 times in 64, and counts as torn instead of as a
/// wrong frame. Flat, saturated colours survive scaling and lossy encodings.
/// The page's JavaScript mirrors `cells(for:)`.
public enum FrameClock {
  public static let cellCount = 8
  public static let dataCells = 6
  /// Frame numbers wrap at 2^18 (about 73 minutes at 60 per second).
  public static let modulus = 1 << (3 * dataCells)
  /// The page counts in 1/60 s steps of its own clock, whatever the display's refresh.
  public static let framesPerSecond = 60.0

  /// A cell's colour, each channel on or off.
  public struct Cell: Equatable, Sendable {
    public var red: Bool
    public var green: Bool
    public var blue: Bool
    public init(red: Bool, green: Bool, blue: Bool) {
      self.red = red; self.green = green; self.blue = blue
    }
    var bits: Int { (red ? 4 : 0) | (green ? 2 : 0) | (blue ? 1 : 0) }
    init(bits: Int) { self.init(red: bits & 4 != 0, green: bits & 2 != 0, blue: bits & 1 != 0) }
  }

  /// The strip for `frame`: data cells, then the two checksum cells.
  public static func cells(for frame: Int) -> [Cell] {
    let value = ((frame % modulus) + modulus) % modulus
    var bits: [Int] = (0..<dataCells).map { index in (value >> (3 * (dataCells - 1 - index))) & 7 }
    let check = checksum(bits)
    bits += [check >> 3, check & 7]
    return bits.map(Cell.init(bits:))
  }

  /// Σ (position + 1) × digit × 7 + position, mod 64: position-weighted, so swapped or mixed cells fail it.
  static func checksum(_ digits: [Int]) -> Int {
    digits.enumerated().reduce(0) { ($0 + ($1.offset + 1) * ($1.element * 7 + $1.offset)) } & 63
  }

  public enum Reading: Equatable, Sendable {
    case frame(Int)
    /// Readable cells that disagree with the parity cell: a strip caught mid-update.
    case torn
    /// A channel too far from both on and off to call (scaling blur, a lossy edge, something covering it).
    case unreadable
  }

  /// Reads a strip from each cell's average channels (0…255): on from 165, off up to 145.
  /// Wide enough for a window drawn in Display P3, where sRGB green (0, 255, 0) reads
  /// (117, 251, 76); narrow enough to reject a blurred edge between two cells.
  /// A strip that can't be read, or fails the checksum, is never taken for a frame.
  public static func read(_ averages: [(red: Double, green: Double, blue: Double)]) -> Reading {
    guard averages.count == cellCount else { return .unreadable }
    var bits: [Int] = []
    for cell in averages {
      var value = 0
      for (shift, channel) in [(2, cell.red), (1, cell.green), (0, cell.blue)] {
        if channel >= 165 {
          value |= 1 << shift
        } else if channel > 145 {
          return .unreadable
        }
      }
      bits.append(value)
    }
    let digits = Array(bits.prefix(dataCells))
    guard checksum(digits) == bits[dataCells] << 3 | bits[dataCells + 1] else { return .torn }
    return .frame(digits.reduce(0) { $0 << 3 | $1 })
  }
}

/// A BGRA image (a captured window) to find and read the strip in.
public struct FrameClockImage {
  public let width: Int
  public let height: Int
  public let bytesPerRow: Int
  public let pixels: UnsafePointer<UInt8>

  public init(width: Int, height: Int, bytesPerRow: Int, pixels: UnsafePointer<UInt8>) {
    self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.pixels = pixels
  }

  /// Orange (255, 128, 0) after scaling, colour conversion or a lossy encoding.
  static func isCalibrationColour(_ red: Double, _ green: Double, _ blue: Double) -> Bool {
    red > 190 && green > 85 && green < 175 && blue < 110
  }

  func pixel(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double) {
    let offset = y * bytesPerRow + x * 4
    return (Double(pixels[offset + 2]), Double(pixels[offset + 1]), Double(pixels[offset]))
  }

  /// The orange calibration strip's bounds, in pixels: the tallest block of
  /// consecutive rows holding a long orange run (at least 8 px per cell), so a
  /// stray orange icon, or a browser toolbar tinted to match, doesn't count.
  public func locateStrip() -> (x: Int, y: Int, width: Int, height: Int)? {
    let minimumRun = 8 * FrameClock.cellCount
    var best: (x: Int, y: Int, width: Int, height: Int)?
    var block: (minX: Int, maxX: Int, top: Int)?
    func close(at y: Int) {
      guard let current = block else { return }
      let candidate = (current.minX, current.top, current.maxX - current.minX, y - current.top)
      if candidate.3 > (best?.height ?? 0) { best = candidate }
      block = nil
    }
    for y in 0..<height {
      var runStart = -1, bestStart = 0, bestLength = 0
      for x in 0...width {
        let (red, green, blue) = x < width ? pixel(x, y) : (0, 0, 0)
        if Self.isCalibrationColour(red, green, blue) {
          if runStart < 0 { runStart = x }
        } else if runStart >= 0 {
          if x - runStart > bestLength { (bestStart, bestLength) = (runStart, x - runStart) }
          runStart = -1
        }
      }
      if bestLength >= minimumRun {
        let current = block ?? (bestStart, bestStart + bestLength, y)
        block = (min(current.minX, bestStart), max(current.maxX, bestStart + bestLength), current.top)
      } else {
        close(at: y)
      }
    }
    close(at: height)
    guard let strip = best, strip.height >= 4, strip.width >= 3 * strip.height else { return nil }
    return strip
  }

  /// Each cell's average colour over its middle (a third of its width and half its height).
  public func cellAverages(
    in strip: (x: Int, y: Int, width: Int, height: Int)
  ) -> [(
    red: Double, green: Double, blue: Double
  )] {
    let cellWidth = Double(strip.width) / Double(FrameClock.cellCount)
    let y0 = strip.y + strip.height / 4, y1 = max(y0 + 1, strip.y + strip.height * 3 / 4)
    return (0..<FrameClock.cellCount).map { index in
      let x0 = strip.x + Int(cellWidth * (Double(index) + 1.0 / 3)),
        x1 = max(
          x0 + 1, strip.x + Int(cellWidth * (Double(index) + 2.0 / 3)))
      var red = 0.0, green = 0.0, blue = 0.0, n = 0.0
      for y in stride(from: y0, to: min(y1, height), by: 1) {
        for x in stride(from: x0, to: min(x1, width), by: 1) {
          let value = pixel(x, y)
          red += value.red; green += value.green; blue += value.blue; n += 1
        }
      }
      return n > 0 ? (red / n, green / n, blue / n) : (0, 0, 0)
    }
  }
}

/// One viewer's readings over a capture: what it showed, and when.
public struct FrameClockTimeline: Sendable {
  public struct Sample: Sendable, Equatable {
    /// Seconds on the capture clock (shared by every window captured together).
    public var time: Double
    public var reading: FrameClock.Reading
    public init(time: Double, reading: FrameClock.Reading) { self.time = time; self.reading = reading }
  }

  public var samples: [Sample]
  public init(samples: [Sample]) { self.samples = samples.sorted { $0.time < $1.time } }

  /// The frames read, in time order, keeping only the first capture of each new frame (an update appearing).
  public var updates: [(time: Double, frame: Int)] {
    var result: [(Double, Int)] = []
    for sample in samples {
      guard case .frame(let frame) = sample.reading else { continue }
      if result.last?.1 != frame { result.append((sample.time, frame)) }
    }
    return result
  }

  public struct Summary: Codable, Equatable, Sendable {
    public var seconds: Double
    /// New host frames shown per second.
    public var updatesPerSecond: Double
    /// The share of the host's frames (60/s) that were ever shown.
    public var hostFramesShown: Double
    public var gapP50Milliseconds: Double
    public var gapP95Milliseconds: Double
    public var gapMaximumMilliseconds: Double
    /// Captures that caught the strip half-updated, and ones that couldn't be read at all.
    public var tornFraction: Double
    public var unreadableFraction: Double
  }

  public var summary: Summary? {
    let updates = self.updates
    guard let first = updates.first, let last = updates.last, updates.count >= 2, last.time > first.time else {
      return nil
    }
    let seconds = last.time - first.time
    let gaps = zip(updates, updates.dropFirst()).map { ($1.time - $0.time) * 1000 }
    let hostSpan = Double(last.frame - first.frame)
    let torn = samples.filter { $0.reading == .torn }.count,
      unreadable = samples.filter {
        $0.reading == .unreadable
      }.count
    return Summary(
      seconds: seconds, updatesPerSecond: Double(updates.count - 1) / seconds,
      hostFramesShown: hostSpan > 0 ? Double(updates.count - 1) / hostSpan : 0,
      gapP50Milliseconds: Self.percentile(gaps, 0.5), gapP95Milliseconds: Self.percentile(gaps, 0.95),
      gapMaximumMilliseconds: gaps.max() ?? 0, tornFraction: Double(torn) / Double(samples.count),
      unreadableFraction: Double(unreadable) / Double(samples.count))
  }

  /// The frame shown at `time`: the last one read at or before it.
  public func frame(at time: Double) -> Int? {
    var shown: Int?
    for update in updates {
      if update.time > time { break }
      shown = update.frame
    }
    return shown
  }

  /// How far this viewer trails `reference`, in ms, sampled at each of this viewer's updates:
  /// (reference's frame − this viewer's frame) at the same capture instant, in host frames × 1000/60.
  public func lag(behind reference: FrameClockTimeline) -> (p50: Double, p95: Double)? {
    let lags = (updates + reference.updates.map { ($0.time, -1) }).map(\.time).sorted().compactMap {
      time -> Double? in
      guard let mine = frame(at: time), let theirs = reference.frame(at: time) else { return nil }
      return Double(theirs - mine) * 1000 / FrameClock.framesPerSecond
    }
    guard !lags.isEmpty else { return nil }
    return (Self.percentile(lags, 0.5), Self.percentile(lags, 0.95))
  }

  static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
  }
}
