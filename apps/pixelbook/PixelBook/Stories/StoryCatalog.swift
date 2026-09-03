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
        "Item labels are arbitrary views. A command-palette row with symbol, detail, and shortcut; the subsequence filter; inline navigation so Return runs the first match."
    ) {
      RichItemsStory()
    },
    Story(
      id: "filters",
      title: "Filters",
      summary:
        "The three Filter presets, switchable in the inspector. Filtering is the caller's one-liner; the popup never filters on its own."
    ) {
      FiltersStory()
    },
    Story(
      id: "navigation",
      title: "Navigation",
      summary:
        "Loop and auto-highlight, switchable in the inspector. Together they are the .inline preset; both off is .menu."
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
        "Root(isDisabled:) dims items and ignores the pointer, arrows, Return, and accessories while a choice is taking effect; Escape still dismisses. Toggle it in the inspector."
    ) {
      DisabledStory()
    },
    Story(
      id: "custom-style",
      title: "Custom style",
      summary:
        "Style swaps the highlight material for a flat fill and the system scroller for the mini one — each switchable in the inspector, over a list long enough to scroll."
    ) {
      CustomStyleStory()
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
        "A pinned action under the list, reachable as the last keyboard target. The escape hatch for managing what the list shows."
    ) {
      FooterStory()
    },
  ]

  static func story(id: String?) -> Story? {
    guard let id else { return nil }
    return all.first { $0.id == id }
  }
}
