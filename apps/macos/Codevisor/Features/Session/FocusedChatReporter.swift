import SwiftUI

struct FocusedChatReporter: View {
  let candidate: () -> UUID?
  let report: (UUID?) -> Void

  var body: some View {
    Color.clear
      .onChange(of: candidate(), initial: true) { _, candidate in report(candidate) }
  }
}
