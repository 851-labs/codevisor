import SwiftUI

struct FirstLaunchLocalDataFailure: View {
  let message: String
  let retry: () -> Void
  let showDataFolder: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Text("Codevisor couldn't open its local data.\n\(message)")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      HStack {
        Button("Try Again", action: retry)
          .buttonStyle(.borderedProminent)
        Button("Show Data Folder", action: showDataFolder)
      }
      .controlSize(.large)
    }
  }
}
