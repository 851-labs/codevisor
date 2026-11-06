import CodevisorCoreMac
import ComposableArchitecture
import ScreenSharing
import SwiftUI

struct ScreenSharingDetailsPopover: View {
  let store: StoreOf<ScreenSharingViewer>

  private static let width: CGFloat = 300
  private static let maxHeight: CGFloat = 600
  private static let padding: CGFloat = 10
  private static let placeholder = "Connection details will appear when the screen share is ready."

  var body: some View {
    ViewThatFits(in: .vertical) {
      details
      ScrollView { details }
    }
    .frame(maxHeight: Self.maxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: Self.width)
  }

  private var details: some View {
    Group {
      if let diagnostics = store.endpoint?.diagnostics {
        ScreenSharingDiagnosticsCards(diagnostics: diagnostics)
      } else {
        ScreenSharingDetailsCard {
          Text(store.message ?? Self.placeholder)
            .foregroundStyle(.secondary)
        }
      }
    }
    .monospacedDigit()
    .padding(Self.padding)
  }
}
