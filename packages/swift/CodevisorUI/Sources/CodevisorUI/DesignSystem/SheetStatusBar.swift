#if os(iOS)
  import SwiftUI

  public struct SheetStatusBar: View {
    private let status: String?

    public init(_ status: String?) { self.status = status }

    public var body: some View {
      if let status {
        VStack(spacing: 0) {
          Divider()
          HStack(spacing: 0) {
            SheetActivityLabel(status)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  extension View {
    public func sheetStatus(_ status: String?) -> some View {
      safeAreaInset(edge: .bottom, spacing: 0) { SheetStatusBar(status) }
        .animation(.default, value: status)
    }
  }
#endif
