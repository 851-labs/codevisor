import CodevisorCore
import SwiftUI

struct MachineNameText: View {
  let name: String
  let ephemeral: CloudEphemeralOrigin?

  var body: some View {
    Text(name)
    if let ephemeral {
      Text(ephemeral.label)
        .foregroundStyle(.secondary)
    }
  }
}
