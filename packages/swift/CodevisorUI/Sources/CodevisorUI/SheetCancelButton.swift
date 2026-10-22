#if os(macOS)
  import SwiftUI

  public struct SheetCancelButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
      self.action = action
    }

    public var body: some View {
      Button("Cancel", role: .cancel, action: action)
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
    }
  }
#endif
