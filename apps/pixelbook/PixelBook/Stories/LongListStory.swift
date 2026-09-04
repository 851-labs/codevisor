import Autocomplete
import SwiftUI

struct LongListStory: View {
  @State private var pinsHeight = true
  @State private var count = 1000
  @State private var selection: Language?
  private var items: [Language] { SampleData.many(count) }
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: items) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
    .autocompleteSizing(pinsHeight ? .stable : .fitResults)
    .popupSurface()
    .storyInspector {
      Section("List") {
        Toggle("Stable search height", isOn: $pinsHeight)
        Picker("Items", selection: $count) {
          Text("200").tag(200)
          Text("1,000").tag(1000)
          Text("10,000").tag(10000)
        }
      }
      SelectionSection(value: selection?.name)
    }
  }
}
