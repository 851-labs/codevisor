import AppKit

@MainActor
final class ChromiumDropSuspension {
  private struct Registration {
    weak var view: NSView?
    let types: [NSPasteboard.PasteboardType]
  }

  private var suspended: [Registration] = []

  func suspend(in root: NSView) {
    let registrations = Self.dropTargets(in: root).map { Registration(view: $0, types: $0.registeredDraggedTypes) }
    registrations.forEach { $0.view?.unregisterDraggedTypes() }
    suspended += registrations
  }

  func resume() {
    for registration in suspended {
      registration.view?.registerForDraggedTypes(registration.types)
    }
    suspended = []
  }

  private static func dropTargets(in view: NSView) -> [NSView] {
    let own = view.registeredDraggedTypes.isEmpty ? [] : [view]
    return own + view.subviews.flatMap(dropTargets(in:))
  }
}
