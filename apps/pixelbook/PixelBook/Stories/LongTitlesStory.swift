import Autocomplete
import SwiftUI

/// Provider-owned names can be arbitrarily long. `Metrics.popupWidth` grows
/// the popup to its maximum and rows truncate.
struct LongTitlesStory: View {
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var selection: Language? = SampleData.longTitles.first

  private let items = SampleData.longTitles
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return items }
    return items.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  private var width: CGFloat {
    metrics.popupWidth(fitting: items.map(\.name))
  }

  var body: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Filter models")
      Autocomplete.List(height: metrics.listHeight(itemCount: items.count)) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching models")
        }
        ForEach(matches) { item in
          Autocomplete.Item(id: item.id, isSelected: item == selection, action: { selection = item }) { _ in
            Text(item.name)
              .lineLimit(1)
          }
        }
      }
    }
    .frame(width: width)
    .popupSurface()
    .storyInspector {
      Section("Popup") {
        LabeledContent("Width", value: "\(Int(width)) pt")
        LabeledContent("Bounds", value: "\(Int(metrics.minimumWidth))–\(Int(metrics.maximumWidth)) pt")
      }
      SelectionSection(value: selection?.name)
    }
  }
}
