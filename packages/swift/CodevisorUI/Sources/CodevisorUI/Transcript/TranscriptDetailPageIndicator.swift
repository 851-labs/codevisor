import CodevisorCore
import SwiftUI
import TranscriptKit

/// The native viewport requests the next detail page before this edge is
/// reached. Its stable footprint preserves geometry during the request.
struct TranscriptDetailPageIndicator: View {
  let request: TranscriptDetailPageRequest
  let controller: SessionController

  var body: some View {
    Group {
      if controller.isLoadingTranscriptDetails(request.itemID) {
        ProgressView().controlSize(.small)
          .accessibilityLabel("Loading worked details")
      } else {
        Color.clear
      }
    }.frame(height: 16)
  }
}
