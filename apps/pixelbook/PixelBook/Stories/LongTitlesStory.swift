import Autocomplete
import SwiftUI

struct LongTitlesStory: View {
  @State private var selection: Language?
  private let languages = SampleData.longTitles
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Languages", selection: $selection, options: languages) { language in
        Autocomplete.Choice(language.name, value: Optional(language))
      }.labelsHidden()
    }
    .popupSurface()
    .storyInspector { SelectionSection(value: selection?.name) }
  }
}
