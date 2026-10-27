import CodevisorCore
import SwiftUI

struct ConfigFieldGeneratedValue: View {
  let field: ServerConfigField
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(field.label) {
        CopyableValue(value: value)
      }
      if let help = field.help {
        Text(help)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
