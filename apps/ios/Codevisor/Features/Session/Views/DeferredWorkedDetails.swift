import CodevisorCore
import CodevisorUI
import SwiftUI

/// Historical turns arrive without their worked detail; expanding the section
/// hydrates just that turn's bounded event set through the shared controller.
struct DeferredWorkedDetails: View {
    let controller: SessionController
    let itemId: String
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Button("Retry loading worked details") { failed = false }
            } else {
                ShimmeringText(text: "Loading worked details…")
                    .task {
                        if await !controller.loadTranscriptDetails(itemId) {
                            failed = true
                        }
                    }
            }
        }
        .font(.callout)
    }
}
