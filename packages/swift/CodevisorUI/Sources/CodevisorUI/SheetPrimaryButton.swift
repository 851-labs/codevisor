#if os(macOS)
  import SwiftUI

  public struct SheetPrimaryButton: View {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
      self.title = title
      self.isEnabled = isEnabled
      self.action = action
    }

    public var body: some View {
      Button(title, action: action)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
    }
  }
#endif
