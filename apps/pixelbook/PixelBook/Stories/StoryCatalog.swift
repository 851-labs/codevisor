import SwiftUI

enum StoryCatalog {
  static let all: [Story] = [
    Story(
      id: "basic",
      title: "Basic",
      summary:
        "A selection-bound Picker inside Suggestions. The package owns filtering, highlighting, empty states, and sizing."
    ) {
      BasicStory()
    },
    Story(
      id: "groups",
      title: "Groups",
      summary:
        "Named picker groups. Matching a group name includes its choices; empty groups disappear automatically."
    ) {
      GroupsStory()
    },
    Story(
      id: "rich-items",
      title: "Rich items",
      summary:
        "Semantic commands with icons and working local keyboard shortcuts, plus subsequence matching."
    ) {
      RichItemsStory()
    },
    Story(
      id: "filters",
      title: "Filters",
      summary:
        "Switch among three matching policies without taking ownership of filtering or navigation."
    ) {
      FiltersStory()
    },
    Story(
      id: "navigation",
      title: "Navigation",
      summary:
        "Loop and initial auto-highlight. Together they are the .inline preset; both off is .menu. Searching highlights the first match with either preset."
    ) {
      NavigationStory()
    },
    Story(
      id: "long-list",
      title: "Long list",
      summary:
        "Up to 10,000 lazily rendered rows. Navigation includes offscreen choices; search reuses catalog measurements."
    ) {
      LongListStory()
    },
    Story(
      id: "long-titles",
      title: "Long titles",
      summary: "Width is measured and cached automatically. Long titles truncate visually while remaining accessible."
    ) {
      LongTitlesStory()
    },
    Story(
      id: "empty",
      title: "Empty",
      summary: "Distinct no-content and no-match states, owned by the shared engine."
    ) {
      EmptyStory()
    },
    Story(
      id: "disabled",
      title: "Disabled",
      summary:
        "Standard disabled state prevents all activation. Disabled choices stay visible and are skipped by keyboard navigation."
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
        "A selection binding derives checkmarks and activation. No separate isSelected flags or row assignment callbacks."
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
        "Ordered favorites with caller-owned storage, keyboard-accessible stars, named accessibility actions, and live reordering."
    ) {
      FavoritesStory()
    },
    Story(
      id: "popover",
      title: "Popover",
      summary:
        "Menu owns the trigger and popover lifecycle. Search starts fresh and keeps stable dimensions; selection or Escape dismisses."
    ) {
      PopoverStory()
    },
    Story(
      id: "actions",
      title: "Actions",
      summary:
        "Management commands share filtering and navigation with choices, separated by an ordinary section divider."
    ) {
      ActionsStory()
    },
    Story(
      id: "parameters", title: "Multiple selections",
      summary: "Independent Effort and Speed bindings in one searchable menu."
    ) { ParametersStory() },
    Story(
      id: "loading", title: "Loading and errors",
      summary: "Explicit loading, error, and ready presentation without custom filtering logic."
    ) { LoadingStory() },
    Story(
      id: "appearance", title: "Appearance and RTL",
      summary: "Live font changes, directional layout, and paired custom highlight colors."
    ) { AppearanceStory() },
    Story(
      id: "focus", title: "Focus and text input",
      summary: "Native text commands, composition, scoped shortcuts, and unhandled submit behavior."
    ) { FocusStory() },

  ]

  static func story(id: String?) -> Story? {
    guard let id else { return nil }
    return all.first { $0.id == id }
  }
}
