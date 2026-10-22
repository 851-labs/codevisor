import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First launch")
struct AppSettingsFirstLaunchTests {
  @Test("Claims the first launch exactly once per client")
  func claimsOnce() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)

    #expect(model.claimFirstLaunch())
    #expect(!model.claimFirstLaunch())
    #expect(!AppSettingsModel(store: store).claimFirstLaunch())
  }

  @Test("Never treats an existing install as a first launch")
  func ignoresExistingInstall() throws {
    let store = InMemoryStore()
    try store.saveData(Data(#"{"hasCompletedOnboarding": true}"#.utf8), forKey: "settings")

    #expect(!AppSettingsModel(store: store).claimFirstLaunch())
  }
}
