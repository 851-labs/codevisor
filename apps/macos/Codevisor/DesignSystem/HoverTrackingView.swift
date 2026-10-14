import SwiftUI
import AppKit

private struct HoverTrackingSuspendedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var hoverTrackingSuspended: Bool {
    get { self[HoverTrackingSuspendedKey.self] }
    set { self[HoverTrackingSuspendedKey.self] = newValue }
  }
}

extension View {
  func hoverTracking(
    _ isHovered: Binding<Bool>,
    respectsSuspension: Bool = true
  ) -> some View {
    background(
      HoverTrackingView(
        isHovered: isHovered,
        respectsSuspension: respectsSuspension
      ))
  }
}

private struct HoverTrackingView: NSViewRepresentable {
  @Binding var isHovered: Bool
  let respectsSuspension: Bool

  func makeNSView(context: Context) -> TrackingNSView {
    let view = TrackingNSView()
    view.onChange = { isHovered = $0 }
    view.isSuspended = respectsSuspension && context.environment.hoverTrackingSuspended
    return view
  }

  func updateNSView(_ view: TrackingNSView, context: Context) {
    view.onChange = { isHovered = $0 }
    view.isSuspended = respectsSuspension && context.environment.hoverTrackingSuspended
  }

  final class TrackingNSView: NSView {
    var onChange: ((Bool) -> Void)?
    var isSuspended = false {
      didSet {
        guard isSuspended != oldValue else { return }
        if isSuspended { onChange?(false) }
        updateTrackingAreas()
      }
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      guard !isSuspended else { return }
      addTrackingArea(
        NSTrackingArea(
          rect: .zero,
          options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
          owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
  }
}
