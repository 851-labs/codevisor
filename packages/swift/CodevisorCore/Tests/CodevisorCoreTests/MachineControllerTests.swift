import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("MachineController")
struct MachineControllerTests {
  @Test("Registry starts with local machine selected")
  func localDefault() {
    let (controller, projectList, _) = makeController()

    #expect(controller.machines == [.local])
    #expect(controller.selectedMachine == .local)
    #expect(projectList.selectedServerId == "local")
  }

  /// A registry as released builds persisted it: directly paired remotes,
  /// retired appearance metadata, and a selection.
  private func legacyRegistry(selecting selectedMachineId: String) -> Data {
    Data(
      """
      {
        "selectedMachineId": "\(selectedMachineId)",
        "hasExplicitMachineSelection": true,
        "localAppearance": {"symbolName": "laptopcomputer"},
        "remoteMachines": [{
          "id": "remote-studio-49361",
          "name": "Studio",
          "baseURL": "http://studio:49361",
          "kind": "remote",
          "token": "hm_secret",
          "cloudDeviceId": "dev-studio"
        }]
      }
      """.utf8)
  }

  @Test("Retired directly paired machines are dropped, and their selection falls back to local")
  func retiredRemotesAreDropped() throws {
    let store = InMemoryStore()
    try store.saveData(legacyRegistry(selecting: "remote-studio-49361"), forKey: "machines")

    let (controller, _, provider) = makeController(store: store)
    provider.cloudMachines = [makeCloudMachine(deviceId: "dev-studio", name: "Studio")]

    #expect(controller.machines == [.local])
    #expect(controller.selectedMachineId == "local")
    // The retired record's cloud link no longer hides the account entry.
    #expect(controller.allMachines.map(\.id) == ["local", "cloud:dev-studio"])
  }

  @Test("A cloud selection survives, and the next save strips every retired key")
  func legacyKeysAreStripped() throws {
    let store = InMemoryStore()
    try store.saveData(legacyRegistry(selecting: "cloud:dev-1"), forKey: "machines")

    let (controller, _, _) = makeController(store: store)
    #expect(controller.selectedMachineId == "cloud:dev-1")
    controller.resetSelection()

    let persistedData = try #require(store.loadData(forKey: "machines"))
    let persisted = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
    #expect(persisted.keys.sorted() == ["selectedMachineId"])
    #expect(persisted["selectedMachineId"] as? String == "local")
  }
}
