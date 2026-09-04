#if canImport(AppKit)
  import SwiftUI

  public extension Autocomplete {
    /// An ordinary menu option. Actions such as "New Project…" use the same
    /// representation and search behavior as choices that carry a checkmark.
    struct Option<ID: Hashable>: Identifiable {
      public let id: ID
      public let title: String
      public let keywords: [String]
      public let icon: Image?
      public let shortcut: KeyboardShortcut?
      public let isSelected: Bool
      public let isDisabled: Bool
      public let help: String?
      public let action: () -> Void

      public init(
        id: ID,
        title: String,
        keywords: [String] = [],
        icon: Image? = nil,
        shortcut: KeyboardShortcut? = nil,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
      ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.icon = icon
        self.shortcut = shortcut
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
      }
    }

    /// A complete searchable menu. Owns the query, filtering, empty state,
    /// separators, keyboard navigation, and sizing. The app supplies options
    /// and their actions, and presents this view in a popover or other surface.
    /// Width and height fit the unfiltered collection so typing is stable.
    struct Menu<ID: Hashable>: View {
      let sections: [Section<Option<ID>>]
      let prompt: String
      let searchAccessibilityLabel: String
      let emptyMessage: String
      let filter: Filter
      let showsCheckmarks: Bool
      let onDismiss: () -> Void

      @Environment(\.autocompleteStyle) private var style
      @State private var query = ""
      @State private var highlight: Highlight<ID>

      public init(
        sections: [Section<Option<ID>>],
        prompt: String = "Search",
        searchAccessibilityLabel: String,
        emptyMessage: String = "No matches",
        filter: Filter = .contains,
        showsCheckmarks: Bool = false,
        onDismiss: @escaping () -> Void
      ) {
        self.sections = sections
        self.prompt = prompt
        self.searchAccessibilityLabel = searchAccessibilityLabel
        self.emptyMessage = emptyMessage
        self.filter = filter
        self.showsCheckmarks = showsCheckmarks
        self.onDismiss = onDismiss
        _highlight = State(initialValue: Highlight<ID>(navigation: .menu))
      }

      public var body: some View {
        let catalog = results(for: "")
        let results = results(for: query)
        let metrics = style.metrics
        let showsIcons = catalog.items.contains { $0.icon != nil }
        Root(highlight: highlight, showsCheckmarks: showsCheckmarks, showsIcons: showsIcons, onDismiss: onDismiss) {
          Input(text: $query, prompt: prompt, accessibilityLabel: searchAccessibilityLabel, focusesOnAppear: true)
          List(height: metrics.listHeight(for: catalog)) {
            if results.isEmpty {
              Empty(emptyMessage)
            }
            ForEach(results.sections) { section in
              if section.id != results.sections.first?.id {
                Divider()
              }
              if let title = section.title {
                GroupLabel(title)
              }
              ForEach(section.items) { option in
                optionRow(option)
              }
            }
          }
        }
        .frame(
          width: metrics.popupWidth(
            fitting: catalog.items.map(\.title) + catalog.sections.compactMap(\.title),
            hasIcons: showsIcons,
            showsCheckmarks: showsCheckmarks,
            shortcuts: catalog.items.compactMap(\.shortcut)
          )
        )
        .onAppear { query = "" }
      }

      private func results(for query: String) -> Results<Option<ID>> {
        Results(sections: sections, query: query, filter: filter) { [$0.title] + $0.keywords }
      }

      @ViewBuilder
      private func optionRow(_ option: Option<ID>) -> some View {
        let row = Item(
          id: option.id,
          icon: option.icon,
          shortcut: option.shortcut,
          isSelected: option.isSelected,
          isDisabled: option.isDisabled,
          action: {
            onDismiss()
            option.action()
          }
        ) { _ in
          Text(option.title)
            .lineLimit(1)
        }
        if let help = option.help {
          row.help(help)
        } else {
          row
        }
      }
    }
  }
#endif
