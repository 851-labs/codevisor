import AppKit
import SwiftUI

enum PixelBookAppearance: String, CaseIterable, Identifiable {
  case system = "System"
  case light = "Light"
  case dark = "Dark"

  var id: String { rawValue }

  /// `nil` follows the system.
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

struct PixelBookRootView: View {
  @State private var selectedStoryID: String? = StoryCatalog.all.first?.id
  @State private var appearance: PixelBookAppearance = .system
  @State private var showsInspector = true
  @State private var searchText = ""
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @FocusState private var searchFocused: Bool

  private var filteredStories: [Story] {
    let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
    return StoryCatalog.all.filter { story in
      terms.allSatisfy { term in
        [story.title, story.group.rawValue, story.summary].contains { $0.localizedStandardContains(term) }
      }
    }
  }

  var body: some View {
    let stories = filteredStories
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $selectedStoryID) {
        ForEach(StoryGroup.allCases) { group in
          let groupStories = stories.filter { $0.group == group }
          if !groupStories.isEmpty {
            Section(group.rawValue) {
              ForEach(groupStories) { story in
                Text(story.title)
                  .tag(story.id)
              }
            }
          }
        }
      }
      .overlay {
        if stories.isEmpty {
          ContentUnavailableView.search(text: searchText)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    } detail: {
      if let story = StoryCatalog.story(id: selectedStoryID) {
        story.content()
          // Fresh @State per story so variants never share picker state.
          .id(story.id)
          .environment(\.currentStory, story)
          .environment(\.showsStoryInspector, $showsInspector)
          .navigationTitle(story.group.rawValue)
          .navigationSubtitle(story.title)
      } else {
        ContentUnavailableView("Pick a story", systemImage: "square.grid.2x2")
      }
    }
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search stories")
    .searchFocused($searchFocused)
    .onSubmit(of: .search) {
      if let story = filteredStories.first { selectedStoryID = story.id }
    }
    .onKeyPress(.return) {
      guard searchFocused, let story = filteredStories.first else { return .ignored }
      selectedStoryID = story.id
      return .handled
    }
    .focusedSceneValue(\.findStory) {
      columnVisibility = .all
      searchFocused = true
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Picker("Appearance", selection: $appearance) {
          ForEach(PixelBookAppearance.allCases) { appearance in
            Text(appearance.rawValue).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
        .help("Preview the story in light or dark appearance")
      }
      ToolbarItem(placement: .primaryAction) {
        // A toolbar Toggle draws its own on-state; the tooltip names the
        // action, and ⌥⌘I is the system-wide inspector shortcut.
        Toggle(isOn: $showsInspector) {
          Label("Inspector", systemImage: "info.circle")
        }
        .help(showsInspector ? "Hide Inspector" : "Show Inspector")
        .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }
    .frame(minWidth: 900, minHeight: 600)
    // Hide the toolbar backdrop once, window-wide, so each column's content
    // color runs under the title bar. Doing it per column (or re-asserting
    // the separator style from a probe) fights AppKit frame by frame while a
    // column collapses and makes the layout stutter.
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .background(WindowFrameGuard())
    // Set the AppKit appearance rather than `preferredColorScheme`: the
    // SwiftUI modifier re-hosts the window content on macOS and leaves the
    // chrome and content disagreeing when it flips back to the system
    // value. The app-wide appearance also reaches popovers.
    .onChange(of: appearance, initial: true) { _, appearance in
      NSApp.appearance = appearance.nsAppearance
    }
  }
}
