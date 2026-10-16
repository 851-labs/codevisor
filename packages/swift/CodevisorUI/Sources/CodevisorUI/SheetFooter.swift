#if os(macOS)
  import SwiftUI

  public struct SheetFooter<Actions: View>: View {
    private let status: String?
    private let actions: Actions

    public init(status: String? = nil, @ViewBuilder actions: () -> Actions) {
      self.status = status
      self.actions = actions()
    }

    public var body: some View {
      VStack(spacing: 0) {
        Divider()
        HStack(spacing: 12) {
          if let status {
            SheetActivityLabel(status)
          }
          Spacer()
          actions
        }
        .controlSize(.regular)
        .padding(20)
      }
      .animation(.default, value: status)
    }
  }
#endif
