import CodevisorCore
import SwiftUI

struct SandboxChoicePicker: View {
  let field: ServerSandboxField
  @Binding var selection: String

  var body: some View {
    #if os(iOS)
      VStack(alignment: .leading, spacing: 4) {
        Picker(field.label, selection: $selection) { choices }
        if let description = field.description {
          Text(description)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    #else
      Picker(selection: $selection) {
        choices
      } label: {
        Text(field.label)
        if let description = field.description { Text(description) }
      }
    #endif
  }

  private var choices: some View {
    ForEach(field.choices ?? [], id: \.value) { Text($0.label).tag($0.value) }
  }
}
