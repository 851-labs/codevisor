#if canImport(AppKit)
  import SwiftUI

  public extension Autocomplete {
    /// Actions pinned below the scrolling results, visible for every query.
    /// Footer entries share the menu's keyboard navigation and dismissal.
    struct Footer: View, AutocompleteMenuContent {
      private let id: AnyHashable
      private let entries: [Entry]
      private var isDisabled = false

      public init(id: AnyHashable, @ContentBuilder content: () -> [Entry]) {
        self.id = id
        entries = content()
      }

      public var body: some View { EmptyView() }
      public var autocompleteEntries: [Entry] {
        [Entry(kind: .footer(id, entries)).disabling(isDisabled)]
      }

      public func disabled(_ disabled: Bool = true) -> Self {
        var copy = self; copy.isDisabled = disabled; return copy
      }
    }
  }
#endif
