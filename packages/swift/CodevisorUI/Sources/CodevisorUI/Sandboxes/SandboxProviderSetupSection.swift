import CodevisorCore
import SwiftUI

public struct SandboxProviderSetupSection: View {
  let vendors: [ServerSandboxVendor]
  let onChoose: (ServerSandboxVendor) -> Void

  public init(vendors: [ServerSandboxVendor], onChoose: @escaping (ServerSandboxVendor) -> Void) {
    self.vendors = vendors
    self.onChoose = onChoose
  }

  public var body: some View {
    Section {
      SandboxVendorList(vendors: vendors, onChoose: onChoose)
    } header: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Set Up a Provider")
        Text("A provider is where your sandboxes run. Each one can have profiles for different sizes.")
          .font(.subheadline)
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
      }
      .textCase(nil)
      .padding(.bottom, 4)
    }
  }
}
