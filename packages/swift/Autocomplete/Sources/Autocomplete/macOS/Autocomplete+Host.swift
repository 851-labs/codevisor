#if canImport(AppKit)
  import AppKit
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

      /// The popup's `Input` field, if it has one. The key monitor only acts
      /// while that field is editing, so a popup rendered inline (a pane's
      /// new-tab page, a picker under a text view) never steals arrows and
      /// Return from whatever else the user focused.
      @ObservationIgnored weak var inputField: NSSearchField?

      /// Whether a key event belongs to this popup: same window, and — when
      /// the popup has an input — that input is the one being edited.
      func wantsKeyEvent(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, event.window === window else { return false }
        guard let inputField else { return true }
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate === inputField
      }

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
