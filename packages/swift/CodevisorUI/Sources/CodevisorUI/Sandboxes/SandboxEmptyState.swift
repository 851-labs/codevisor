import SwiftUI

public struct SandboxEmptyState: View {
  private static let opticalCenter = 0.4

  let onAdd: (() -> Void)?

  public init(onAdd: (() -> Void)? = nil) {
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
      Label("No Sandbox Providers", systemImage: "shippingbox")
    } description: {
      Text("Add a provider to run chats in a sandbox.")
    } actions: {
      if let onAdd {
        Button("Add Provider…", action: onAdd)
          .buttonStyle(.borderedProminent)
      }
    }
  }
}
