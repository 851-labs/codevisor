import SwiftUI

extension EnvironmentValues {
  @Entry var currentStory: Story?

  @Entry var showsStoryInspector: Binding<Bool> = .constant(true)
}

extension View {
  func storyInspector(@ViewBuilder content: @escaping () -> some View) -> some View {
    modifier(StoryInspectorModifier(inspector: content))
  }
}

private struct StoryInspectorModifier<Inspector: View>: ViewModifier {
  let inspector: () -> Inspector

  @Environment(\.currentStory) private var story
  @Environment(\.showsStoryInspector) private var showsInspector

  func body(content: Content) -> some View {
    content
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .inspector(isPresented: showsInspector) {
        Form {
          if let story {
            Section("Description") {
              Text(story.summary)
                .foregroundStyle(.secondary)
            }
          }
          inspector()
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
      }
  }
}

struct SelectionSection: View {
  let value: String?

  var body: some View {
    Section("Selection") {
      LabeledContent("Item", value: value ?? "None")
    }
  }
}
