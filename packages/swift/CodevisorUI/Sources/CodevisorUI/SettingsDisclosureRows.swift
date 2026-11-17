import SwiftUI

struct SettingsDisclosureRows<Label: View, Content: View>: View {
  @Binding var isExpanded: Bool
  var chevronEdge: HorizontalEdge = .leading
  @ViewBuilder let label: () -> Label
  @ViewBuilder let content: () -> Content

  var body: some View {
    #if os(macOS)
      SettingsDisclosureRow(isExpanded: $isExpanded, chevronEdge: chevronEdge, label: label) { EmptyView() }
      if isExpanded { content() }
    #else
      DisclosureGroup(isExpanded: $isExpanded, content: content, label: label)
    #endif
  }
}
