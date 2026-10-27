import CodevisorCore
import SwiftUI

struct MachineNameText: View {
  let name: String
  let sandbox: CloudEphemeralOrigin?

  var body: some View {
    Text(name)
    if let sandbox {
      Text(sandbox.label)
        .foregroundStyle(.secondary)
    }
  }
}
