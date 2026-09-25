import Testing

@testable import ScreenSharingRigKit

/// The cross-app frame clock (851-2358): the strip's code, finding and reading
/// it in a captured window, and the per-viewer statistics.
struct FrameClockTests {
  typealias Averages = [(red: Double, green: Double, blue: Double)]

  static func averages(_ cells: [FrameClock.Cell]) -> Averages {
    cells.map { ($0.red ? 255 : 0, $0.green ? 255 : 0, $0.blue ? 255 : 0) }
  }

  @Test func everyFrameNumberSurvivesTheStrip() {
    for frame in [0, 1, 7, 8, 59, 60, 4095, 123_456, FrameClock.modulus - 1] {
      #expect(FrameClock.read(Self.averages(FrameClock.cells(for: frame))) == .frame(frame))
    }
    #expect(FrameClock.read(Self.averages(FrameClock.cells(for: FrameClock.modulus + 5))) == .frame(5))
  }

  @Test func aHalfUpdatedStripIsTornAndABlurredOneUnreadable() {
    // A VNC update that covered only part of the strip: old cells, then new ones, at every split.
    var caught = 0, splits = 0
    for frame in stride(from: 0, to: 3000, by: 7) {
      for split in 1..<FrameClock.cellCount {
        let mixed =
          Array(FrameClock.cells(for: frame).prefix(split)) + Array(FrameClock.cells(for: frame + 1).dropFirst(split))
        guard mixed != FrameClock.cells(for: frame), mixed != FrameClock.cells(for: frame + 1) else { continue }
        splits += 1
        if FrameClock.read(Self.averages(mixed)) == .torn { caught += 1 }
      }
    }
    #expect(Double(caught) / Double(splits) > 0.95, "\(caught) of \(splits) torn strips caught")
    var blurred = Self.averages(FrameClock.cells(for: 100))
    blurred[2].green = 175
    #expect(FrameClock.read(blurred) == .unreadable)
    // Lossy but decisive values still read.
    let lossy: Averages = Self.averages(FrameClock.cells(for: 100)).map {
      (red: $0.red == 255 ? 200.0 : 40.0, green: $0.green == 255 ? 190.0 : 90.0, blue: $0.blue == 255 ? 230.0 : 10.0)
    }
    #expect(FrameClock.read(lossy) == .frame(100))
    // The rig's window as captured on a P3 display: the sRGB primaries, converted.
    let p3: [Int: (red: Double, green: Double, blue: Double)] = [
      0: (0, 0, 0), 1: (0, 0, 245), 2: (117, 251, 76), 3: (117, 251, 253), 4: (234, 51, 35), 5: (234, 51, 247),
      6: (255, 255, 84), 7: (255, 255, 255),
    ]
    let converted: Averages = FrameClock.cells(for: 76_543).map {
      p3[($0.red ? 4 : 0) | ($0.green ? 2 : 0) | ($0.blue ? 1 : 0)]!
    }
    #expect(FrameClock.read(converted) == .frame(76_543))
    // Another capture of the rig's window: green (154, 247, 95), red (214, 75, 48).
    let shifted: [Int: (red: Double, green: Double, blue: Double)] = [
      0: (0, 0, 0), 1: (23, 0, 238), 2: (154, 247, 95), 3: (154, 247, 250), 4: (214, 75, 48), 5: (214, 75, 238),
      6: (255, 255, 95), 7: (255, 255, 255),
    ]
    let recoloured: Averages = FrameClock.cells(for: 12_345).map {
      shifted[($0.red ? 4 : 0) | ($0.green ? 2 : 0) | ($0.blue ? 1 : 0)]!
    }
    #expect(FrameClock.read(recoloured) == .frame(12_345))
    #expect(FrameClock.read(Array(lossy.prefix(7))) == .unreadable)
  }

  /// A 400 × 300 BGRA window: grey, a small orange icon and an orange-tinted toolbar (not the strip), and the strip at (40, 30), 320 × 24.
  static func window(strip: [FrameClock.Cell]?) -> [UInt8] {
    let width = 400, height = 300
    var pixels = [UInt8](repeating: 90, count: width * height * 4)
    func paint(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) {
      for y in y0..<(y0 + h) {
        for x in x0..<(x0 + w) {
          let o = (y * width + x) * 4
          pixels[o] = rgb.2; pixels[o + 1] = rgb.1; pixels[o + 2] = rgb.0; pixels[o + 3] = 255
        }
      }
    }
    paint(350, 250, 10, 10, (255, 128, 0))
    // While calibrating, a browser toolbar tinted to match the page, above the strip with a gap: not part of it.
    if strip == nil { paint(0, 0, 400, 12, (250, 120, 10)) }
    for index in 0..<FrameClock.cellCount {
      let cell = strip?[index]
      let rgb: (UInt8, UInt8, UInt8) =
        cell.map { ($0.red ? 255 : 0, $0.green ? 255 : 0, $0.blue ? 255 : 0) } ?? (255, 128, 0)
      paint(40 + index * 40, 30, 40, 24, rgb)
    }
    return pixels
  }

  @Test func theStripIsFoundWhileOrangeAndReadAfterwards() throws {
    let calibration = Self.window(strip: nil)
    let strip = try calibration.withUnsafeBufferPointer { buffer in
      try #require(
        FrameClockImage(width: 400, height: 300, bytesPerRow: 1600, pixels: buffer.baseAddress!).locateStrip())
    }
    #expect(strip.x == 40 && strip.y == 30 && strip.width == 320 && strip.height == 24, "\(strip)")
    let counting = Self.window(strip: FrameClock.cells(for: 98_765))
    let reading = counting.withUnsafeBufferPointer { buffer in
      let image = FrameClockImage(width: 400, height: 300, bytesPerRow: 1600, pixels: buffer.baseAddress!)
      return FrameClock.read(image.cellAverages(in: strip))
    }
    #expect(reading == .frame(98_765))
    // Counting cells (magenta among them) never look like the calibration strip.
    let magentaHeavy = Self.window(strip: FrameClock.cells(for: 0o555555))
    let relocated = magentaHeavy.withUnsafeBufferPointer {
      FrameClockImage(width: 400, height: 300, bytesPerRow: 1600, pixels: $0.baseAddress!).locateStrip()
    }
    #expect(relocated == nil)
    // Without the strip only the icon and toolbar are orange: neither counts.
    let blank = [UInt8](repeating: 90, count: 400 * 300 * 4)
    let found = blank.withUnsafeBufferPointer {
      FrameClockImage(width: 400, height: 300, bytesPerRow: 1600, pixels: $0.baseAddress!).locateStrip()
    }
    #expect(found == nil)
  }

  static func timeline(
    fps: Double, seconds: Double, startFrame: Int, capturesPerSecond: Double = 60
  )
    -> FrameClockTimeline
  {
    // The viewer shows host frame startFrame + k·(60/fps) at k/fps s; captures run at 60 Hz.
    let step = FrameClock.framesPerSecond / fps
    let samples = stride(from: 0.0, to: seconds, by: 1 / capturesPerSecond).map { time -> FrameClockTimeline.Sample in
      let shown = startFrame + Int((time * fps).rounded(.down) * step)
      return .init(time: time, reading: .frame(shown))
    }
    return FrameClockTimeline(samples: samples)
  }

  @Test func summariesAndLagComeFromWhatEachViewerShowed() throws {
    // Apple-like: 30 updates/s, current. Ours: 5 updates/s, 30 host frames (500 ms) behind.
    let reference = Self.timeline(fps: 30, seconds: 4, startFrame: 1000)
    let ours = Self.timeline(fps: 5, seconds: 4, startFrame: 970)
    let fast = try #require(reference.summary), slow = try #require(ours.summary)
    #expect(abs(fast.updatesPerSecond - 30) < 1 && abs(fast.hostFramesShown - 0.5) < 0.02)
    #expect(abs(slow.updatesPerSecond - 5) < 0.2 && abs(slow.gapP50Milliseconds - 200) < 17)
    let lag = try #require(ours.lag(behind: reference))
    // 500 ms of offset plus up to 200 ms of our own staleness between updates.
    #expect(lag.p50 >= 500 && lag.p50 <= 700, "\(lag)")
    var withTears = ours.samples
    withTears[3].reading = .torn
    withTears[4].reading = .unreadable
    let torn = try #require(FrameClockTimeline(samples: withTears).summary)
    #expect(torn.tornFraction > 0 && torn.unreadableFraction > 0)
    #expect(FrameClockTimeline(samples: []).summary == nil)
  }

  /// 851-2371: image age from a host page counting wall-clock frames (`?clock=epoch`).
  @Test func imageAgeComesFromWallClockFramesAndTheClockOffset() throws {
    // The host is 2.5 s ahead of this Mac. Each capture at viewer time t shows the frame the
    // host drew 120 ms earlier (host time t + 2.5 − 0.12), in 60ths of a second since 1970.
    let viewerWallMinusCapture = 1_700_000_000.0, hostMinusViewer = 2.5
    let samples = stride(from: 0.0, to: 3, by: 0.1).map { t -> FrameClockTimeline.Sample in
      let hostDrew = t + viewerWallMinusCapture + hostMinusViewer - 0.12
      let frame = Int((hostDrew * FrameClock.framesPerSecond).rounded(.down)) % FrameClock.modulus
      return .init(time: t, reading: .frame(frame))
    }
    let ages = FrameClockTimeline(samples: samples)
      .imageAges(viewerWallMinusCaptureClock: viewerWallMinusCapture, hostMinusViewer: hostMinusViewer)
    #expect(ages.count == 30)
    #expect(ages.allSatisfy { $0 >= 120 && $0 < 120 + 1000 / FrameClock.framesPerSecond + 1e-6 }, "\(ages.prefix(3))")
    // A clock offset that's slightly wrong shows up as that much age, never as a wrapped period.
    let skewed = FrameClockTimeline(samples: samples)
      .imageAges(viewerWallMinusCaptureClock: viewerWallMinusCapture, hostMinusViewer: hostMinusViewer - 0.2)
    #expect(skewed.allSatisfy { $0 < 0 && $0 > -100 })
  }
}
