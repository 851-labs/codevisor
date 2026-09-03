import SwiftUI

extension EnvironmentValues {
  /// The story being shown, so `.storyInspector` can lead with its description.
  @Entry var currentStory: Story?

  /// Whether PixelBook's inspector column is shown; toggled from the
  /// window toolbar and read by every story.
  @Entry var showsStoryInspector: Binding<Bool> = .constant(true)
}

extension View {
  /// Wrap a story's component in the PixelBook chrome: centered on the native
  /// content background, with a grouped-form inspector in the trailing
  /// column led by the story's description.
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
      // A constant zero minimum: if the column's minimum size changed with
      // each story's popup width, SwiftUI's split-view child would update
      // its constraints mid-layout, which raises on macOS 27 betas.
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      // The canvas never scrolls, so macOS would draw the classic opaque
      // toolbar with a hairline over it. Hide the toolbar's backdrop so the
      // content color runs under the title bar (the same seamless look the
      // product's windows have) and drop the hairline.
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

/// Every story reports what the picker chose the same way.
struct SelectionSection: View {
  let value: String?

  var body: some View {
    Section("Selection") {
      LabeledContent("Item", value: value ?? "None")
    }
  }
}
