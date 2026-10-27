import CodevisorUI
import SwiftUI

struct BlockedPublishersSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      Text("Blocked Publishers")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
      PluginBlockedPublishersView()
      Divider()
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 420, height: 360)
  }
}
