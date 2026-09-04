import SwiftUI

private struct FindStoryKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var findStory: (() -> Void)? {
    get { self[FindStoryKey.self] }
    set { self[FindStoryKey.self] = newValue }
  }
}

struct PixelBookCommands: Commands {
  @FocusedValue(\.findStory) private var findStory

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button("Find Story…", systemImage: "magnifyingglass") { findStory?() }
        .keyboardShortcut("f")
        .disabled(findStory == nil)
    }
  }
}
