#if os(macOS)
  import AppKit
  import SwiftUI

  struct SandboxSheetFields<Content: View>: View {
    private static var groupedFormMargin: CGFloat { 20 }
    private static var sheetChromeHeight: CGFloat { 320 }
    private static var leastRoom: CGFloat { 160 }

    let errorMessage: String?
    @ViewBuilder let content: Content

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Form { content }
          .formStyle(.grouped)
          .scrollContentBackground(.hidden)
          .scrollBounceBehavior(.basedOnSize)
          .frame(maxHeight: room)
          .fixedSize(horizontal: false, vertical: true)
          .mask { Rectangle().padding(.vertical, Self.groupedFormMargin) }
          .padding(-Self.groupedFormMargin)
        if let errorMessage {
          SandboxErrorLabel(message: errorMessage)
        }
      }
    }

    private var room: CGFloat {
      guard let screen = NSScreen.main else { return .infinity }
      return max(Self.leastRoom, screen.visibleFrame.height - Self.sheetChromeHeight)
    }
  }
#endif
