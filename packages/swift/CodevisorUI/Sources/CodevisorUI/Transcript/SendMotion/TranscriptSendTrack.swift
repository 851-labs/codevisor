import QuartzCore

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

final class TranscriptSendTrack: TranscriptSendPlatformView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(UIKit)
      autoresizingMask = [.flexibleWidth, .flexibleHeight]
      isUserInteractionEnabled = false
      backgroundColor = .clear
    #else
      autoresizingMask = [.width, .height]
      wantsLayer = true
    #endif
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

  #if !canImport(UIKit)
    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }
  #endif

  func move(into document: TranscriptSendPlatformView) {
    guard let superview, superview !== document else { return }
    let frame = document.convert(frame, from: superview)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    document.addSubview(self)
    autoresizingMask = []
    #if canImport(UIKit)
      UIView.performWithoutAnimation { self.frame = frame }
    #else
      self.frame = frame
    #endif
    transcriptSendLayer?.zPosition = Self.aboveRows
    CATransaction.commit()
  }

  private static let aboveRows: CGFloat = 1_000

  func shift(by delta: CGSize) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    #if canImport(UIKit)
      UIView.performWithoutAnimation { frame = frame.offsetBy(dx: delta.width, dy: delta.height) }
    #else
      frame = frame.offsetBy(dx: delta.width, dy: delta.height)
    #endif
    CATransaction.commit()
  }
}
