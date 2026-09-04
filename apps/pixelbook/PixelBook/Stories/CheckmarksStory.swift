import Autocomplete
import SwiftUI

/// A menu-style popup: `Root(showsCheckmarks:)` reserves the check column,
/// `Item(isSelected:)` draws the mark, and a `Divider` separates the runs —
/// inset to the title keyline because the column is present.
struct CheckmarksStory: View {
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var effort = "high"
  @State private var speed = "standard"

  private let efforts = ["low", "medium", "high", "x-high", "max"]
  private let speeds = ["standard", "fast"]
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var titles: [String: String] {
    [
      "low": "Low", "medium": "Medium", "high": "High", "x-high": "X-High", "max": "Max",
      "standard": "Standard", "fast": "Fast",
    ]
  }

  private func matches(_ ids: [String]) -> [String] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return ids }
    return ids.filter { Autocomplete.Filter.contains.matches(titles[$0] ?? $0, query: query) }
  }

  var body: some View {
    let visibleEfforts = matches(efforts)
    let visibleSpeeds = matches(speeds)
    Autocomplete.Root(highlight: highlight, showsCheckmarks: true, onDismiss: { query = "" }) {
      Autocomplete.Input(text: $query, prompt: "Search")
      Autocomplete.List(
        height: metrics.listHeight(groupItemCounts: [efforts.count, speeds.count]) + metrics.dividerHeight
      ) {
        if visibleEfforts.isEmpty, visibleSpeeds.isEmpty {
          Autocomplete.Empty("No matching options")
        }
        if !visibleEfforts.isEmpty {
          Autocomplete.Group("Effort") {
            ForEach(visibleEfforts, id: \.self) { id in
              Autocomplete.Item(id: id, isSelected: effort == id, action: { effort = id }) { _ in
                Text(titles[id] ?? id)
              }
            }
          }
        }
        if !visibleEfforts.isEmpty, !visibleSpeeds.isEmpty {
          Autocomplete.Divider()
        }
        if !visibleSpeeds.isEmpty {
          Autocomplete.Group("Speed") {
            ForEach(visibleSpeeds, id: \.self) { id in
              Autocomplete.Item(id: id, isSelected: speed == id, action: { speed = id }) { _ in
                Text(titles[id] ?? id)
              }
            }
          }
        }
      }
    }
    .frame(width: metrics.popupWidth(fitting: Array(titles.values) + ["Effort", "Speed"], showsCheckmarks: true))
    .popupSurface()
    .storyInspector {
      Section("Selection") {
        LabeledContent("Effort", value: titles[effort] ?? effort)
        LabeledContent("Speed", value: titles[speed] ?? speed)
      }
    }
  }
}
