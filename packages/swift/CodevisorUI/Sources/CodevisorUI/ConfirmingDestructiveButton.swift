import SwiftUI

public struct ConfirmingDestructiveButton: View {
  private let title: String
  private let systemImage: String?
  private let action: () -> Void

  public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  public var body: some View {
    #if os(iOS)
      Button(action: action) { label }
        .tint(.red)
    #else
      Button(role: .destructive, action: action) { label }
    #endif
  }

  @ViewBuilder
  private var label: some View {
    if let systemImage {
      Label(title, systemImage: systemImage)
    } else {
      Text(title)
    }
  }
}
