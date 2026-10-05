import CoreImage
import CoreVideo
import Foundation
import Observation
import ScreenSharing

/// The stream's screen for more than one view: a foldable is drawn as its cover and two inner
/// halves, each its own live copy, and folding keeps a still of what the screen last showed.
/// A video source's frames are taken as they arrive and handed to each copy's mailbox.
@MainActor @Observable
final class SimulatorScreenFeed {
  /// How many live copies a device is drawn with at most: a foldable's cover and inner halves.
  nonisolated static let copies = 3

  /// A foldable's other screen is waking: the guest turns it on black, then fades it up from dim,
  /// so its frames are held back (and the screen's still shown) until they're bright and settled.
  private(set) var waking = false

  @ObservationIgnored private var tee: Tee?
  @ObservationIgnored private var image: CGImage?
  @ObservationIgnored private var arrangement: String?
  @ObservationIgnored private var wake: UUID?
  @ObservationIgnored private var pinned: (frame: ScreenSharingVideoFrame, at: Date)?

  /// The source for each copy, fed from `source`. A new `arrangement` (one screen, two halves,
  /// a fold) gets mailboxes of its own: a video view clears its mailbox's callback as it stops,
  /// so views coming and going on a shared one could leave the new one unfed.
  func sources(for source: SimulatorScreenSource?, arrangement: String) -> [SimulatorScreenSource?] {
    switch source {
    case .video(let mailbox, let metrics):
      if tee?.source !== mailbox {
        tee = Tee(source: mailbox)
      } else if arrangement != self.arrangement {
        tee?.renew()
      }
      self.arrangement = arrangement
      image = nil
      return tee?.outputs.map { .video($0, metrics) } ?? []
    case .image(let still):
      tee = nil
      image = still
      return Array(repeating: source, count: Self.copies)
    case nil:
      tee = nil
      image = nil
      return Array(repeating: nil, count: Self.copies)
    }
  }

  /// The stream is moving to another screen: hold its frames until that screen has woken.
  func awaitWake() {
    guard let tee else { return }
    let id = UUID()
    wake = id
    waking = true
    tee.hold { [weak self] in
      Task { @MainActor in
        guard let self, self.wake == id else { return }
        self.wake = nil
        self.waking = false
      }
    }
    // A screen that stays dark (asleep, or showing black) still comes in, a little later.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard let self, self.wake == id else { return }
      self.tee?.release()
      self.wake = nil
      self.waking = false
    }
  }

  /// Keeps the frame showing now for the next `snapshot`: a posture was just asked for, and the
  /// guest's fold will redraw the screen mid-transition before the device says it moved.
  func pin() {
    pinned = tee?.latest.map { (frame: $0, at: Date()) }
  }

  /// What the screen showed last (or when it was pinned, a moment ago), as the framebuffer is laid out.
  func snapshot() -> CGImage? {
    let held = pinned.flatMap { Date().timeIntervalSince($0.at) < 3 ? $0.frame : nil }
    pinned = nil
    guard let frame = held ?? tee?.latest else { return image }
    let picture = CIImage(cvPixelBuffer: frame.pixelBuffer)
    return Self.context.createCGImage(picture, from: picture.extent)
  }

  private static let context = CIContext(options: [.cacheIntermediates: false])

  /// Takes each frame from the receiver's mailbox and puts it in every copy's.
  private final class Tee: @unchecked Sendable {
    let source: ScreenSharingFrameMailbox
    private let lock = NSLock()
    private var last: ScreenSharingVideoFrame?
    private var mailboxes = Tee.fresh()
    private var held: Held?
    private var count = 0

    /// Frames kept back while the next screen wakes.
    private struct Held {
      /// The screen being left's size: its frames still in flight aren't the new screen's.
      var size: CGSize?
      var brightness: Double?
      var woken: () -> Void
    }

    var outputs: [ScreenSharingFrameMailbox] { lock.withLock { mailboxes } }

    private static func fresh() -> [ScreenSharingFrameMailbox] {
      (0..<SimulatorScreenFeed.copies).map { _ in ScreenSharingFrameMailbox() }
    }

    init(source: ScreenSharingFrameMailbox) {
      self.source = source
      source.onFrameAvailable { [weak self] in self?.forward() }
    }

    deinit { source.onFrameAvailable(nil) }

    var latest: ScreenSharingVideoFrame? { lock.withLock { last } }

    private func forward() {
      guard let frame = source.take() else { return }
      let (outputs, number, holding) = lock.withLock {
        last = frame
        count += 1
        return (held == nil ? mailboxes : [], count, held != nil)
      }
      if holding { judge(frame, number: number) }
      for output in outputs { output.put(frame) }
    }

    func hold(woken: @escaping () -> Void) {
      lock.withLock { held = Held(size: last.map { Tee.size($0.pixelBuffer) }, woken: woken) }
    }

    /// Hands on the latest frame and stops holding.
    func release() {
      let (outputs, frame, woken) = lock.withLock {
        let woken = held?.woken
        held = nil
        return (mailboxes, last, woken)
      }
      if let frame { for output in outputs { output.put(frame) } }
      woken?()
    }

    /// Whether a held frame shows the new screen awake: another size than the old screen, lit,
    /// and done fading up (as bright as the last frame, or nothing newer comes for a moment).
    private func judge(_ frame: ScreenSharingVideoFrame, number: Int) {
      let size = Tee.size(frame.pixelBuffer)
      let brightness = SimulatorScreenFeed.brightness(frame.pixelBuffer)
      let settled: Bool? = lock.withLock {
        guard var held else { return nil }
        guard size != held.size, let brightness, brightness > SimulatorScreenFeed.lit else {
          held.brightness = nil
          self.held = held
          return false
        }
        defer {
          held.brightness = brightness
          self.held = held
        }
        return held.brightness.map { abs($0 - brightness) < SimulatorScreenFeed.steady } ?? false
      }
      if settled == true {
        release()
      } else if settled == false, brightness.map({ $0 > SimulatorScreenFeed.lit }) == true {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
          guard let self, self.lock.withLock({ self.held != nil && self.count == number }) else { return }
          self.release()
        }
      }
    }

    private static func size(_ buffer: CVPixelBuffer) -> CGSize {
      CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    /// New mailboxes, holding the latest frame: a still screen sends nothing new, and a fresh
    /// view would stay black until it did.
    func renew() {
      let (outputs, frame) = lock.withLock {
        mailboxes = Tee.fresh()
        return (mailboxes, last)
      }
      if let frame { for output in outputs { output.put(frame) } }
    }
  }

  /// Mean luma (0–255) above which a frame is lit: video-range black is 16.
  nonisolated static let lit = 22.0
  /// How little the mean luma moves between frames once a screen is done fading up.
  nonisolated static let steady = 1.5

  /// A frame's mean luma (0–255) over a grid of samples, for the decoder's luma-first formats;
  /// nil for any other.
  nonisolated static func brightness(_ buffer: CVPixelBuffer) -> Double? {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let wide: Bool
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
      wide = false
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
      wide = true
    default:
      return nil
    }
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    guard width > 0, height > 0 else { return nil }
    let grid = 16
    var total = 0.0
    for row in 0..<grid {
      let y = (row * 2 + 1) * height / (grid * 2)
      let line = base.advanced(by: y * stride)
      for column in 0..<grid {
        let x = (column * 2 + 1) * width / (grid * 2)
        // Ten-bit luma sits in the high bits of each 16-bit sample.
        total +=
          wide
          ? Double(line.load(fromByteOffset: x * 2, as: UInt16.self) >> 8)
          : Double(line.load(fromByteOffset: x, as: UInt8.self))
      }
    }
    return total / Double(grid * grid)
  }
}
