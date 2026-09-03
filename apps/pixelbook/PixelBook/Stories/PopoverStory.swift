import Autocomplete
import SwiftUI

/// The presentation the product uses: a trigger whose popover hosts the
/// popup. The trigger resets the filter and measures the unfiltered list
/// before presenting, so the popover keeps one size while filtering;
/// choosing or Escape closes it.
struct PopoverStory: View {
  @State private var query = ""
  @State private var isPresented = false
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .menu)
  @State private var listHeight: CGFloat?
  @State private var selection: Language?

  private let languages = SampleData.languages
  private let metrics = Autocomplete.Style.xcodeMenu.metrics

  private var matches: [Language] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return languages }
    return languages.filter { Autocomplete.Filter.contains.matches($0.name, query: query) }
  }

  var body: some View {
    Button {
      query = ""
      listHeight = metrics.listHeight(itemCount: languages.count)
      isPresented.toggle()
    } label: {
      Text(selection?.name ?? "Choose a language")
    }
    .buttonStyle(.glass)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      Autocomplete.Root(highlight: highlight, onDismiss: { isPresented = false }) {
        Autocomplete.Input(text: $query, prompt: "Search", focusesOnAppear: true)
        Autocomplete.List(height: listHeight) {
          if matches.isEmpty {
            Autocomplete.Empty("No matching languages")
          }
          ForEach(matches) { language in
            Autocomplete.Item(id: language.id, isSelected: language == selection, action: { choose(language) }) { _ in
              Text(language.name)
            }
          }
        }
      }
      .frame(width: metrics.popupWidth(fitting: languages.map(\.name)))
    }
    .storyInspector {
      Section("Presentation") {
        LabeledContent("Popover", value: isPresented ? "Shown" : "Hidden")
        LabeledContent("Pinned list height", value: listHeight.map { "\(Int($0)) pt" } ?? "—")
      }
      SelectionSection(value: selection?.name)
    }
  }

  private func choose(_ language: Language) {
    selection = language
    isPresented = false
  }
}
