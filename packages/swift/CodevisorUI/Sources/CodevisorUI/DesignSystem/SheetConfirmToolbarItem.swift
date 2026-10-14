#if os(iOS)
  import SwiftUI

  public struct SheetConfirmToolbarItem: ToolbarContent {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
      self.title = title
      self.isEnabled = isEnabled
      self.action = action
    }

    public var body: some ToolbarContent {
      ToolbarItem(placement: .confirmationAction) {
        Button(title, role: .confirm, action: action)
          .disabled(!isEnabled)
      }
    }
  }
#endif
