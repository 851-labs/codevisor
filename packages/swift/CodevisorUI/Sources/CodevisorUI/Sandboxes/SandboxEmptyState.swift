import SwiftUI

public struct SandboxEmptyState: View {
  private static let opticalCenter = 0.4

  let onAdd: () -> Void

  public init(onAdd: @escaping () -> Void) {
    self.onAdd = onAdd
  }

  public var body: some View {
    GeometryReader { proxy in
      content
        .fixedSize(horizontal: false, vertical: true)
        .position(x: proxy.size.width / 2, y: proxy.size.height * Self.opticalCenter)
    }
  }

  private var content: some View {
    ContentUnavailableView {
      Label("No Sandbox Profiles", systemImage: "shippingbox")
    } description: {
      Text("Add a profile to run chats in a sandbox.")
    } actions: {
      Button("Add Profile…", action: onAdd)
        .buttonStyle(.borderedProminent)
    }
  }
}
