import Observation

public extension Autocomplete {
  /// The single highlighted item of a popup. Every input drives the same
  /// value — the pointer, the arrow keys, and a filter that removes the
  /// current item — so what the user sees is always what Return accepts and
  /// what the next arrow press moves from.
  ///
  /// The highlight is deliberately unaware of the list contents. Callers
  /// pass the currently visible ordered targets to every navigation call,
  /// so the same state drives grouped lists, filtered lists, and lists with
  /// footers.
  @MainActor
  @Observable
  final class Highlight<ID: Hashable> {
    /// Which input last moved the highlight, so a container can react
    /// differently (scroll a keyboard target into view; leave a hovered one
    /// alone).
    public enum Source: Sendable, Hashable {
      case keyboard
      case pointer
    }

    public var navigation: Navigation
    public private(set) var highlighted: ID?
    public private(set) var source: Source?

    public init(navigation: Navigation = .menu) {
      self.navigation = navigation
    }

    // MARK: Pointer

    /// The pointer entered an item: it becomes the highlight.
    public func hover(_ id: ID) {
      set(id, source: .pointer)
    }

    /// The pointer left an item. Menus clear the highlight the way NSMenu
    /// does; with `autoHighlight` a highlight must always exist, so it stays
    /// where it is until another input moves it.
    public func endHover(_ id: ID) {
      guard highlighted == id, !navigation.autoHighlight else { return }
      set(nil, source: .pointer)
    }

    // MARK: Keyboard

    /// Forget the highlight, e.g. when the popup is about to be presented.
    public func reset() {
      highlighted = nil
      source = nil
    }

    /// Drop a highlight the list no longer shows (after filtering) and apply
    /// `autoHighlight`.
    public func reconcile(with targets: [ID]) {
      if let highlighted, !targets.contains(highlighted) {
        set(nil, source: .keyboard)
      }
      if highlighted == nil, navigation.autoHighlight {
        set(targets.first, source: .keyboard)
      }
    }

    public func move(by offset: Int, in targets: [ID]) {
      guard !targets.isEmpty else {
        set(nil, source: .keyboard)
        return
      }
      guard let highlighted, let index = targets.firstIndex(of: highlighted) else {
        set(offset < 0 ? targets.last : targets.first, source: .keyboard)
        return
      }
      let nextIndex: Int
      if navigation.loop {
        nextIndex = ((index + offset) % targets.count + targets.count) % targets.count
      } else {
        nextIndex = min(max(index + offset, 0), targets.count - 1)
      }
      set(targets[nextIndex], source: .keyboard)
    }

    public func moveToFirst(in targets: [ID]) {
      set(targets.first, source: .keyboard)
    }

    public func moveToLast(in targets: [ID]) {
      set(targets.last, source: .keyboard)
    }

    /// Route a key command. `accept` receives the highlight only when it is
    /// still among `targets`. Returns whether the command changed state or
    /// fired a callback, so an owner sharing the keyboard (a text editor)
    /// can let unhandled keys fall through.
    @discardableResult
    public func handle(
      _ command: KeyCommand,
      targets: [ID],
      accept: (ID) -> Void,
      dismiss: () -> Void
    ) -> Bool {
      switch command {
      case .moveUp:
        move(by: -1, in: targets)
      case .moveDown:
        move(by: 1, in: targets)
      case .moveToFirst:
        moveToFirst(in: targets)
      case .moveToLast:
        moveToLast(in: targets)
      case .accept:
        guard let highlighted, targets.contains(highlighted) else { return false }
        accept(highlighted)
      case .dismiss:
        dismiss()
      }
      return true
    }

    private func set(_ id: ID?, source: Source) {
      highlighted = id
      self.source = source
    }
  }
}
