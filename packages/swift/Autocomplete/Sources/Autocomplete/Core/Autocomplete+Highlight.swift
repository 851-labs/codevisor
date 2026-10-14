import Foundation
import Observation

extension Autocomplete {
  @MainActor
  @Observable
  final class Highlight<ID: Hashable> {
    enum Source: Sendable, Hashable {
      case keyboard
      case pointer
    }

    var navigation: Navigation
    private(set) var highlighted: ID?
    private(set) var source: Source?
    private var searchQuery = ""

    private var autoHighlights: Bool { navigation.autoHighlight || !searchQuery.isEmpty }

    init(navigation: Navigation = .menu) {
      self.navigation = navigation
    }

    func hover(_ id: ID) {
      set(id, source: .pointer)
    }

    func endHover(_ id: ID) {
      guard highlighted == id, !autoHighlights else { return }
      set(nil, source: .pointer)
    }

    func focus(_ id: ID) { set(id, source: .keyboard) }

    func reset() {
      highlighted = nil
      source = nil
      searchQuery = ""
    }

    func reconcile(with targets: [ID], query: String? = nil) {
      if let query {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized != searchQuery {
          searchQuery = normalized
          set(autoHighlights ? targets.first : nil, source: .keyboard)
          return
        }
      }
      if let highlighted, !targets.contains(highlighted) {
        set(nil, source: .keyboard)
      }
      if highlighted == nil, autoHighlights {
        set(targets.first, source: .keyboard)
      }
    }

    func move(by offset: Int, in targets: [ID]) {
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

    func moveToFirst(in targets: [ID]) {
      set(targets.first, source: .keyboard)
    }

    func moveToLast(in targets: [ID]) {
      set(targets.last, source: .keyboard)
    }

    @discardableResult
    func handle(
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
