import CodevisorCoreMac
import SwiftUI

struct ChromeImportSheet: View {
  let browser: ChromiumBrowserModel
  let signIns: ChromeSignInImport
  @Environment(\.dismiss) private var dismiss
  @State private var selection: ChromeProfile.ID?

  var body: some View {
    SetupSheet(
      symbol: ChromeImportButton.symbol,
      title: "Import from Chrome",
      primaryTitle: signIns.failure == nil ? "Import" : "Try Again",
      canContinue: selection != nil && !signIns.isImporting,
      working: signIns.isImporting,
      message: signIns.failure,
      onCancel: { dismiss() },
      onContinue: importSelected
    ) {
      ForEach(Array(signIns.profiles.profiles.enumerated()), id: \.element.id) { index, profile in
        if index > 0 { Divider() }
        ChromeProfileRow(profile: profile, selected: selection == profile.id) { selection = profile.id }
      }
    }
    .onAppear { selection = signIns.profiles.preferred?.id }
    .onDisappear { signIns.clearFailure() }
  }

  private func importSelected() {
    guard let profile = signIns.profiles.profiles.first(where: { $0.id == selection }) else { return }

    Task {
      if await signIns.importSignIns(from: profile, into: browser) { dismiss() }
    }
  }
}
