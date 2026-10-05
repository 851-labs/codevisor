import CoreImage
import Foundation
import ScreenSharing

/// The stream's screen for more than one view: a foldable open part way is drawn as two halves,
/// each its own live copy, and folding animates from a still of what the screen last showed.
/// A video source's frames are taken as they arrive and handed to each copy's mailbox.
@MainActor
final class SimulatorScreenFeed {
  /// How many live copies a device is drawn with at most (a foldable's two halves).
  nonisolated static let copies = 2

  private var tee: Tee?
  private var image: CGImage?
  private var arrangement: String?

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

  /// What the screen showed last, as the framebuffer is laid out.
  func snapshot() -> CGImage? {
    guard let frame = tee?.latest else { return image }
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
      let outputs = lock.withLock {
        last = frame
        return mailboxes
      }
      for output in outputs { output.put(frame) }
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
}
