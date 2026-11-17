#if os(macOS)
  import SwiftUI

  struct SandboxSheetVendorIcon: View {
    let vendorId: String

    var body: some View {
      CodevisorSymbol.sandboxVendor(vendorId)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }
#endif
