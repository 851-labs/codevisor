import CodevisorCore
import SwiftUI

struct SandboxVendorChoicePage: View {
  let model: SandboxSettingsModel
  let navigate: (SandboxSettingsNavigation) -> Void

  var body: some View {
    SandboxSettingsForm(title: "Choose a Sandbox Vendor") {
      Section {
        SandboxVendorList(vendors: model.vendors.vendors) { vendor in
          navigate(.push(.newProvider(vendorId: vendor.id)))
        }
      }
    }
  }
}
