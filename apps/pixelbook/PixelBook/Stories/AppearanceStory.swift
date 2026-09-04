import Autocomplete
import SwiftUI

struct AppearanceStory: View {
  @State private var rightToLeft = false
  @State private var dark = true
  @State private var fontSize = 13.0
  @State private var selection = ""
  @State private var favorites: [String] = []
  private var style: Autocomplete.Style {
    var metrics = Autocomplete.Metrics()
    metrics.fontSize = fontSize
    return Autocomplete.Style(metrics: metrics, itemHighlight: .fill(.yellow, foreground: .black))
  }
  var body: some View {
    Autocomplete.Suggestions {
      Autocomplete.Picker("Projects", selection: $selection) {
        Autocomplete.Choice("No project", value: "none", systemImage: "folder")
        Autocomplete.Choice("Résumé", value: "resume", systemImage: "folder.fill")
        Autocomplete.Choice("المشروع", value: "arabic", systemImage: "folder.fill")
      }.favorites($favorites)
    }
    .autocompleteStyle(style)
    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    .environment(\.colorScheme, dark ? .dark : .light)
    .popupSurface()
    .storyInspector {
      Section("Appearance") {
        Toggle("Right to left", isOn: $rightToLeft)
        Toggle("Dark", isOn: $dark)
        Slider(value: $fontSize, in: 13...24, step: 1) { Text("Font size") }
        LabeledContent("Font size", value: "\(Int(fontSize)) pt")
      }
    }
  }
}
