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
}
