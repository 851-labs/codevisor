#if canImport(AppKit)
  import Observation
  import SwiftUI

  extension Autocomplete {
    /// What one registered view contributes to keyboard navigation.
    struct Target: Equatable {
      enum Kind {
        case item
        case groupLabel
        case footer
      }

      let id: AnyHashable
      let kind: Kind
    }

    /// Items, group labels, and footers announce themselves upward in tree
    /// order; `Root` reads the result to know what the keyboard can reach and
    /// how tall the list is.
    struct TargetsKey: PreferenceKey {
      static var defaultValue: [Target] { [] }

      static func reduce(value: inout [Target], nextValue: () -> [Target]) {
        value.append(contentsOf: nextValue())
      }
    }

    /// The non-generic relay `Root` places in the environment so the input,
    /// list, items, and footer can talk to it without knowing the ID type.
    @MainActor
    @Observable
    final class Host {
      var isDisabled = false
      var targets: [Target] = []

      /// Bumped whenever the keyboard accepts an item; the matching item runs
      /// its action.
      private(set) var acceptTick = 0
      private(set) var acceptedID: AnyHashable?

      /// Bumped whenever the keyboard target moves; the list scrolls it into
      /// view.
      private(set) var scrollTick = 0
      private(set) var scrollTarget: AnyHashable?

      var send: (KeyCommand) -> Void = { _ in }

      func accept(_ id: AnyHashable) {
        acceptedID = id
        acceptTick += 1
      }

      func scroll(to id: AnyHashable) {
        scrollTarget = id
        scrollTick += 1
      }
    }
  }
#endif
