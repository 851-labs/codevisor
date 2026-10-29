import CodevisorCore
import SwiftUI

struct SandboxVendorChoicePage: View {
  let model: SandboxSettingsModel
  let onChoose: (ServerSandboxVendor) -> Void

  var body: some View {
    SandboxSettingsForm(title: "Choose a Sandbox Vendor") {
      Section {
        SandboxVendorList(vendors: model.vendors.vendors, onChoose: onChoose)
      }
    }
  }
}
