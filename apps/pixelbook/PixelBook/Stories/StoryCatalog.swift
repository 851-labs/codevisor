import SwiftUI

enum StoryCatalog {
  static let all: [Story] = [
    Story(
      id: "basic",
      title: "Basic",
      summary:
        "Root, Input, List, and Items over a flat array. Menu navigation: nothing highlighted until a key is pressed, arrows stop at the ends."
    ) {
      BasicStory()
    },
    Story(
      id: "groups",
      title: "Groups",
      summary:
        "Group labels runs of items. The caller decides how filtering treats a group — here, matching a group's name keeps all of its items."
    ) {
      GroupsStory()
    },
    Story(
      id: "rich-items",
      title: "Rich items",
      summary:
        "Item's first-party icon and shortcut slots, formatted from real KeyboardShortcut values; the subsequence filter; inline navigation so Return runs the first match."
    ) {
      RichItemsStory()
    },
    Story(
      id: "filters",
      title: "Filters",
      summary:
        "The three Filter presets. Filtering is the caller's one-liner; the popup never filters on its own."
    ) {
      FiltersStory()
    },
    Story(
      id: "navigation",
      title: "Navigation",
      summary:
        "Loop and auto-highlight. Together they are the .inline preset; both off is .menu."
    ) {
      NavigationStory()
    },
    Story(
      id: "long-list",
      title: "Long list",
      summary:
        "Two hundred items. The list caps at the style's maximum height, keyboard navigation scrolls the target into view, and a pinned height keeps the popover steady while filtering."
    ) {
      LongListStory()
    },
    Story(
      id: "long-titles",
      title: "Long titles",
      summary: "Metrics.popupWidth grows the popup to its maximum and rows truncate."
    ) {
      LongTitlesStory()
    },
    Story(
      id: "empty",
      title: "Empty",
      summary: "Empty centers a message in the list's visible height, for both no items and no matches."
    ) {
      EmptyStory()
    },
    Story(
      id: "disabled",
      title: "Disabled",
      summary:
        "Root(isDisabled:) dims items and ignores the pointer, arrows, Return, and accessories while a choice is taking effect; Escape still dismisses."
    ) {
      DisabledStory()
    },
    Story(
      id: "custom-style",
      title: "Custom style",
      summary:
        "Style swaps the highlight material for a flat fill and the system scroller for the mini one, over a list long enough to scroll."
    ) {
      CustomStyleStory()
    },
    Story(
      id: "checkmarks",
      title: "Checkmarks",
      summary:
        "Menu(showsCheckmarks:) reserves the check column, and Option(isSelected:) marks the current effort level. Choosing another item moves the checkmark."
    ) {
      CheckmarksStory()
    },
    Story(
      id: "dividers",
      title: "Dividers",
      summary:
        "Menu separates sections with inset dividers. Filtering away a section removes its divider, and keyboard navigation skips separators."
    ) {
      DividersStory()
    },
    Story(
      id: "favorites",
      title: "Favorites accessory",
      summary:
        "A one-off UX from the primitives: a hover-revealed star accessory and a Favorites group that lifts starred items out of their group. The package knows nothing about favorites."
    ) {
      FavoritesStory()
    },
    Story(
      id: "popover",
      title: "Popover",
      summary:
        "The presentation the product uses: a trigger whose popover hosts the popup. The trigger resets the filter and measures the unfiltered list before presenting so the popover never resizes; choosing or Escape closes it."
    ) {
      PopoverStory()
    },
    Story(
      id: "footer",
      title: "Footer",
      summary:
        "Ordinary Items pinned under the list behind a divider — icons, shortcuts, and keyboard navigation included. The escape hatch for managing what the list shows."
    ) {
      FooterStory()
    },
  ]

  static func story(id: String?) -> Story? {
    guard let id else { return nil }
    return all.first { $0.id == id }
  }
}
