import Autocomplete
import SwiftUI

/// Two hundred items: the list caps at the style's maximum height and
/// keyboard navigation scrolls the target into view. Pinning the height to
/// the unfiltered count keeps the popup steady while filtering; unpinned,
/// it shrinks to its matches.
struct LongListStory: View {
  @State private var pinsHeight = true
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var selection: Language?

  private let items = SampleData.many(200)
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return items }
    return items.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  private var listHeight: CGFloat {
    metrics.listHeight(itemCount: pinsHeight ? items.count : matches.count)
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(height: listHeight) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching items")
        }
        ForEach(matches) { item in
          Autocomplete.Item(id: item.id, isSelected: item == selection, action: { selection = item }) { _ in
            Text(item.name)
          }
        }
      }
    }
    .frame(width: metrics.minimumWidth)
    .popupSurface()
    .storyInspector {
      Section("List") {
        Toggle("Pin height to the unfiltered count", isOn: $pinsHeight)
        LabeledContent("Items", value: "\(items.count)")
        LabeledContent("Height", value: "\(Int(listHeight)) pt (max \(Int(metrics.maximumHeight)))")
      }
      SelectionSection(value: selection?.name)
    }
  }
}
