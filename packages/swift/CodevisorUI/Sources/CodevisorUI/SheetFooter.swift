#if os(macOS)
  import SwiftUI

  public struct SheetFooter<Actions: View>: View {
    @Environment(\.theme) private var theme
    private let status: String?
    private let actions: Actions

    public init(status: String? = nil, @ViewBuilder actions: () -> Actions) {
      self.status = status
      self.actions = actions()
    }

    public var body: some View {
      VStack(spacing: 0) {
        Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
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
      .themedSurface(.sheet)
    }
  }
#endif
