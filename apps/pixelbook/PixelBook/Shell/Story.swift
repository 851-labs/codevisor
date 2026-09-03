import SwiftUI

enum StoryGroup: String, CaseIterable, Identifiable {
  case autocomplete = "Autocomplete"

  var id: String { rawValue }
}

/// One example. The content view owns its state and presents its own
/// inspector with `.storyInspector { … }`.
struct Story: Identifiable, Hashable {
  let id: String
  let group: StoryGroup
  let title: String
  let summary: String
  let content: () -> AnyView

  init(
    id: String,
    group: StoryGroup = .autocomplete,
    title: String,
    summary: String,
    @ViewBuilder content: @escaping () -> some View
  ) {
    self.id = id
    self.group = group
    self.title = title
    self.summary = summary
    self.content = { AnyView(content()) }
  }

  static func == (lhs: Story, rhs: Story) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
