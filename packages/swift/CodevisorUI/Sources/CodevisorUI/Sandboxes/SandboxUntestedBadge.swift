import SwiftUI

public struct SandboxUntestedBadge: View {
  public init() {}

  public var body: some View {
    Text("Untested")
      .font(.caption2.weight(.medium))
      .foregroundStyle(.orange)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.orange.opacity(0.15), in: .capsule)
      .help("Built from the provider's documentation and not yet tried with a real account")
  }
}
