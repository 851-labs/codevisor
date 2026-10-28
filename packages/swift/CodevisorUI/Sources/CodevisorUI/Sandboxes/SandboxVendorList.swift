import CodevisorCore
import SwiftUI

public struct SandboxVendorList: View {
  let vendors: [ServerSandboxVendor]
  let onChoose: (ServerSandboxVendor) -> Void

  public init(vendors: [ServerSandboxVendor], onChoose: @escaping (ServerSandboxVendor) -> Void) {
    self.vendors = vendors
    self.onChoose = onChoose
  }

  public var body: some View {
    ForEach(vendors) { vendor in
      SandboxChoiceRow(icon: CodevisorSymbol.sandboxVendor(vendor.id), title: vendor.displayName) {
        onChoose(vendor)
      }
    }
  }
}
