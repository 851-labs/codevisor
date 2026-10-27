import SwiftUI

struct SandboxSelect<Extra: View>: View {
  struct Option: Identifiable {
    let id: String
    let title: String
    let icon: Image
  }

  let label: String
  let placeholder: String
  let options: [Option]
  let selection: String?
  let onSelect: (String) -> Void
  @ViewBuilder let extra: Extra

  var body: some View {
    LabeledContent(label) {
      Menu {
        Picker(label, selection: choice) {
          ForEach(options) { option in
            Label {
              Text(option.title)
            } icon: {
              option.icon
            }
            .tag(Optional(option.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        extra
      } label: {
        HStack(spacing: 4) {
          Text(selectedTitle ?? placeholder)
            .foregroundStyle(valueStyle)
          #if os(iOS)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          #endif
        }
      }
      .fixedSize()
      #if os(iOS)
        .buttonStyle(.plain)
      #endif
      .accessibilityLabel(label)
      .accessibilityValue(selectedTitle ?? placeholder)
    }
  }

  private var valueStyle: HierarchicalShapeStyle {
    #if os(iOS)
      .secondary
    #else
      selectedTitle == nil ? .secondary : .primary
    #endif
  }

  private var selectedTitle: String? {
    options.first { $0.id == selection }?.title
  }

  private var choice: Binding<String?> {
    Binding(get: { selection }, set: { if let id = $0 { onSelect(id) } })
  }
}
