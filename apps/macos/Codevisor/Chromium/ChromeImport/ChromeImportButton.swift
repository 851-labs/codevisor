import CodevisorCoreMac
import SwiftUI

struct ChromeImportButton: View {
  static let title = "Import Chrome Sign-Ins"
  static let symbol = "person.badge.key"

  let browser: ChromiumBrowserModel
  let signIns: ChromeSignInImport
  @State private var choosingProfile = false

  var body: some View {
    if !signIns.profiles.profiles.isEmpty {
      Button(action: start) { ChromeImportButtonIcon(phase: signIns.phase).frame(width: 34, height: 32) }
        .buttonStyle(.plain)
        .disabled(signIns.isImporting)
        .help(Self.title)
        .accessibilityLabel(Self.title)
        .sheet(isPresented: $choosingProfile) { ChromeImportSheet(browser: browser, signIns: signIns) }
        .alert("Couldn’t Import Chrome Sign-Ins", isPresented: showsFailure) {
          Button("Try Again", action: start)
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(signIns.failure ?? "")
        }
    }
  }

  private var showsFailure: Binding<Bool> {
    Binding(
      get: { signIns.failure != nil && !choosingProfile },
      set: { shown in if !shown { signIns.clearFailure() } }
    )
  }

  private func start() {
    signIns.clearFailure()
    Task {
      await signIns.loadProfiles()
      guard signIns.profiles.profiles.count == 1, let profile = signIns.profiles.preferred else {
        choosingProfile = !signIns.profiles.profiles.isEmpty
        return
      }
      await signIns.importSignIns(from: profile, into: browser)
    }
  }
}

private struct ChromeImportButtonIcon: View {
  let phase: ChromeSignInImport.Phase

  var body: some View {
    switch phase {
    case .importing:
      ProgressView().controlSize(.small)
    case .imported:
      Image(systemName: "checkmark").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
    case .idle, .failed:
      Image(systemName: ChromeImportButton.symbol)
    }
  }
}
