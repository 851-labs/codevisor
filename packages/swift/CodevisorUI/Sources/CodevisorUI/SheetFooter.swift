#if os(macOS)
  import SwiftUI

  /// Standard sheet actions, independent of the controls in the sheet's content.
  public struct SheetFooter<Actions: View>: View {
    private let actions: Actions

    public init(@ViewBuilder actions: () -> Actions) {
      self.actions = actions()
    }

    public var body: some View {
      VStack(spacing: 0) {
        Divider()
        HStack(spacing: 12) {
          Spacer()
          actions
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(20)
      }
    }
  }
#endif
