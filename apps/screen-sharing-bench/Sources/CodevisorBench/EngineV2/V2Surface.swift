import AppKit
import ScreenSharing
import ScreenSharingV2

@MainActor
struct V2Surface {
  let view: NSView
  private let stopper: () -> Void

  init(_ presentation: V2Presentation, mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) throws {
    switch presentation {
    case .displayLink:
      let view = try ScreenSharingV2DisplayLinkView(mailbox: mailbox, metrics: metrics)
      self.view = view
      stopper = { view.stop() }
    case .arrival:
      let surface = try ScreenSharingVideoSurface(mailbox: mailbox, metrics: metrics)
      view = surface
      stopper = { surface.stop() }
    }
  }

  func stop() {
    stopper()
  }
}
