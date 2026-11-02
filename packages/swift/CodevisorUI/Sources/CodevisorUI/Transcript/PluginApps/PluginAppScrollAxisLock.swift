#if os(macOS)
  import AppKit

  struct PluginAppScrollAxisLock {
    enum Axis {
      case horizontal
      case vertical
    }

    private var locked: Axis?

    mutating func axis(of event: NSEvent) -> Axis? {
      if Self.startsGesture(event) { locked = nil }
      if locked == nil { locked = Self.dominantAxis(of: event) }
      return locked
    }

    private static func startsGesture(_ event: NSEvent) -> Bool {
      let unphased = event.phase.isEmpty && event.momentumPhase.isEmpty
      return unphased || event.phase.contains(.began) || event.phase.contains(.mayBegin)
    }

    private static func dominantAxis(of event: NSEvent) -> Axis? {
      if event.modifierFlags.contains(.shift) { return .horizontal }
      guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return nil }

      return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? .vertical : .horizontal
    }
  }
#endif
