import SwiftUI

public struct PluginConsentNotice: View {
  let name: String
  public init(name: String) { self.name = name }

  public var body: some View {
    Text(
      "By installing, you allow \(name) to access your computer and receive workspace details and anything you share, across your devices. [Plugin terms](https://codevisor.dev/terms#plugins)."
    )
    .font(.footnote)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
