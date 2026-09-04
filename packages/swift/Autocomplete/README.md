# Autocomplete

Searchable macOS menus and inline suggestions, with selection bindings, commands, ordered favorites, and custom labels. The menu owns search, empty states, layout, navigation, accessibility, and dismissal. Persistence and domain operations stay in the app.

```swift
Autocomplete.Menu {
  Autocomplete.Picker("Effort", selection: $effort) {
    ForEach(Effort.allCases) { value in
      Autocomplete.Choice(value.title, value: value)
    }
  }
  Autocomplete.Picker("Speed", selection: $speed) {
    for value in Speed.allCases {
      Autocomplete.Choice(value.title, value: value)
    }
  }
} label: {
  Text(parameterSummary)
}
.autocompleteSearchLabel("Search model parameters")
.autocompleteSectionDividers(.hidden)
```

A `Picker` used directly as a SwiftUI view supplies its own menu trigger showing the selected choice. Inside `Menu` or `Suggestions`, it contributes a group of choices. Checkmarks derive from the binding, including when several pickers share a menu. `labelsHidden()` hides a group's heading without removing its search terms.

## Commands and favorites

```swift
Autocomplete.Menu {
  Autocomplete.Picker("Projects", selection: $projectID, options: projects) { project in
    Autocomplete.Choice(project.name, value: project.id, systemImage: "folder.fill")
      .searchTerms([project.path])
  }
  .favorites($favoriteProjectIDs)
  .labelsHidden()

  Autocomplete.Section(id: "actions") {
    Autocomplete.Action("New Project…", systemImage: "folder.badge.plus", action: createProject)
      .keyboardShortcut("n", modifiers: [.command, .shift])
  }
} label: {
  Label(projectName, systemImage: "folder")
}
```

Favorites store values in the order they were starred. Missing values remain in the caller's storage; duplicate stored values produce one row. Favorites have no heading. A favorite keeps its original identity when promoted, filtered, or restored to its group. Optional selection values work, so `nil` can represent a favoritable “No project” choice. Use `favoritable(false)` to exclude an individual choice.

A highlighted choice can be favorited or unfavorited with **Shift-Command-F**, by pressing Tab to focus its star and then Space or Return, through its context menu, or using its named accessibility action. Secondary actions never select a choice or dismiss the menu. Custom `SecondaryAction` arrays support additional controls and local shortcuts.

Commands and choices share the same search collection; action-only results never coexist with an unrelated empty-state message. Section labels are searchable and disappear with their last matching item.

## Inline use and focus

```swift
Autocomplete.Suggestions(query: $query, focus: searchFocus, onSubmit: submitUnmatchedQuery) {
  Autocomplete.Action("New Chat", systemImage: "text.bubble", action: newChat)
  Autocomplete.Action("New Terminal", systemImage: "terminal", action: newTerminal)
}
.autocompleteSearchLabel("Search new tab options")
```

The query binding is optional. `Suggestions` owns a query when none is provided. It defaults to inline navigation: the first result is highlighted and arrows wrap. Menus start unhighlighted, highlight the first result on search edits, and stop at the list ends. Override with `autocompleteNavigation(_:)`.

Inline search does not steal focus on appearance. Use `autocompleteSearchFocused($focused)` for a focus binding, or retain an `Autocomplete.InputFocus` and call `focus()` for repeated imperative focus requests such as activating a pane. Requests made before window attachment remain pending. An unhandled Return reaches `onSubmit`; Escape clears an inline query or invokes `onCancel`. Menu selection and Escape dismiss its popover. `Menu(isPresented:)` optionally exposes presentation state.

All activation paths respect the inherited `.disabled` environment and per-entry `.disabled()` modifiers. Disabled entries stay visible but are excluded from keyboard navigation. Native text commands and marked-text composition are processed by AppKit. Registered shortcuts apply only while the autocomplete owns focus; unmodified typing stays in the search field.

## Labels, identity, and matching

Choice and Action support custom `icon` and `label` builders. Their explicit title supplies search, measurement, and accessibility text, so a rich or asynchronous icon does not require a different implementation path. Supply localized titles with `String(localized:)` or localized domain data. Package-owned prompts, favorite actions, spoken key names, and result-count plurals use the package's localization bundle.

Choice values must be unique within their picker. Section and picker IDs must be stable and unique in their containing scope. Titles are convenient default section/action IDs; provide explicit IDs for changing or localized titles. The engine validates duplicates in debug builds and scopes values by their containing groups, allowing different pickers to use the same value type and value.

The content builders support `if`, `switch`, `for`, and simple `ForEach` expressions. Use builder-level conditionals when conditionally including entries. These are semantic adapters, not arbitrary SwiftUI-view introspection: regular SwiftUI Button/Picker contents and arbitrary view modifiers cannot be decoded into searchable entries. Entry methods such as `disabled`, `help`, `searchTerms`, `keyboardShortcut`, and `secondaryActions` preserve the semantic content type.

Use `autocompleteFilter(.contains)`, `.startsWith`, `.subsequence`, or a custom `Autocomplete.Filter`. Presets normalize case and diacritics, and trim query boundaries. Custom predicates receive original candidate strings and the trimmed query. Catalog terms are prepared once; each edit only matches results. Highlight and layout updates reuse the current result snapshot. Content or locale changes rebuild the catalog, and filter changes invalidate matching.

## Presentation and accessibility

- `autocompleteSizing(.stable)` keeps the unfiltered catalog size while searching; `.fitResults` sizes to matches. Both obey style bounds.
- `autocompleteEmptyMessage(_:noItems:)` distinguishes no matches from an empty catalog.
- `autocompleteLoadingState(.loading(message))`, `.failure(message)`, and `.ready` control status presentation. The app owns fetching, cancellation, and retry actions.
- `autocompleteDismissBehavior(.automatic)`, `.onSelection`, or `.never` configures primary activation. Automatic dismisses menus and keeps inline suggestions open.
- `autocompleteStyle(_:)` controls typography, dimensions, scrollers, and highlights. A custom fill takes an explicit contrasting foreground: `.fill(.yellow, foreground: .black)`.

Increasing `metrics.fontSize` also expands row heights, heading line boxes, symbol columns, and accessory targets. Configured dimensions remain minimums, while corner radii stay tied to the popup's geometry. Only a final row that visually meets the viewport's bottom edge receives concentric bottom corners; spare space left by stable search sizing keeps ordinary row corners.

The native search field links to its result scroll view. Headings expose heading semantics, choices expose current selection, and favorites expose their state and secondary actions. Keyboard result changes and result counts produce debounced accessibility announcements while search stays editable. Labels remain available to accessibility even when visually truncated. Rows use a lazy stack; complete keyboard order comes from semantic data, including offscreen results.

## Performance verification

A local release-optimized benchmark with an all-matching, diacritic-insensitive query and 25% favorites measured the following mean search work over 20 iterations:

| Catalog | Previous implementation | Prepared catalog |
| --- | ---: | ---: |
| 1,000 rows | 11.7 ms | 2.2 ms |
| 10,000 rows | 119.5 ms | 22.0 ms |

The previous path rebuilt full and filtered results and measured width each time. The new path reuses preparation and measurements across search edits. Initial preparation still costs time (about 138 ms for 10,000 rows in this run); these figures exclude view rendering and do not represent end-to-end frame timings. Tests also verify navigation to offscreen items, filtering cache invalidation, and width cache invalidation.

## Migration from the original API

Replace `Root`/`Input`/`List`/`Item` compositions and `Menu(sections:)` with `Menu` or `Suggestions`, `Picker`/`Choice`, and `Action`/`Section`. Delete caller-owned filtering, highlight state, row-count sizing, and manual `isSelected`/assignment pairs. Management footers become ordinary action sections. The former `Results`, `Option`, and presentation primitives are removed; there is one result and activation path.

The macOS composer, model picker, new-tab page, and PixelBook examples use this API. PixelBook includes disabled choices, focus handoff, multiple selections, loading/error states, favorites/reordering, RTL, larger fonts, and catalogs up to 10,000 rows.

```sh
swift test --package-path packages/swift --scratch-path tmp/build/swift-tests --filter AutocompleteTests
```
