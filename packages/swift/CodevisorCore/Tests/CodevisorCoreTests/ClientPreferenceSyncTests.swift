import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("ClientPreferenceSync")
struct ClientPreferenceSyncTests {
  private let namespace = ClientPreferenceSync.namespace

  private enum Detail: String, Codable {
    case pr
  }

  private func receive(
    _ environment: AppEnvironment,
    _ key: String,
    _ value: JSONValue,
    deleted: Bool = false,
    wallMs: Int = 20_000_000_000_000
  ) {
    environment.configSync.applyRemoteChange(
      namespace: namespace,
      entries: [
        ServerSyncEntry(
          key: key,
          value: value,
          deleted: deleted ? true : nil,
          timestamp: ServerSyncTimestamp(wallMs: wallMs, counter: 0, deviceId: "other-device")
        )
      ]
    )
  }

  private func synced(_ environment: AppEnvironment, _ key: String) -> ServerSyncEntry? {
    environment.configSync.entries(namespace: namespace).first { $0.key == key }
  }

  @Test("Local changes to shared preferences publish; other preferences stay on the device")
  func localChangesPublish() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    environment.syncClientPreferences(["grouping"], preferences: preferences)

    preferences.set("machine", forKey: "grouping")
    preferences.set(true, forKey: "listExpanded")
    #expect(synced(environment, "grouping")?.value == .string("machine"))
    #expect(synced(environment, "listExpanded") == nil)

    preferences.removeValue(forKey: "grouping")
    #expect(synced(environment, "grouping")?.deleted == true)
  }

  @Test("Changes from another device apply locally without being republished")
  func remoteChangesApply() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    environment.syncClientPreferences(["grouping", "pins"], preferences: preferences)

    receive(environment, "grouping", .string("project"))
    receive(environment, "pins", .array([.string("a")]))
    #expect(preferences.value(forKey: "grouping", default: "flat") == "project")
    #expect(preferences.value(forKey: "pins", default: [String]()) == ["a"])

    receive(environment, "pins", .null, deleted: true, wallMs: 30_000_000_000_000)
    #expect(preferences.valueIfPresent(forKey: "pins", as: [String].self) == nil)
    #expect(environment.configSync.entries(namespace: namespace).allSatisfy { $0.timestamp.deviceId == "other-device" })
  }

  @Test("Values from before sync yield to other devices, except list items, which merge once")
  func upgradeMergesLists() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    preferences.set("machine", forKey: "grouping")
    preferences.set(["a"], forKey: "pins")
    environment.syncClientPreferences(["grouping", "pins"], preferences: preferences)
    #expect(synced(environment, "pins")?.value == .array([.string("a")]))

    receive(environment, "grouping", .string("project"), wallMs: 1)
    receive(environment, "pins", .array([.string("b")]), wallMs: 1)
    #expect(preferences.value(forKey: "grouping", default: "flat") == "project")
    #expect(preferences.value(forKey: "pins", default: [String]()) == ["b", "a"])
    #expect(synced(environment, "pins")?.value == .array([.string("b"), .string("a")]))
    #expect(synced(environment, "pins")?.timestamp.deviceId == environment.configSync.deviceId)

    receive(environment, "pins", .array([.string("c")]))
    #expect(preferences.value(forKey: "pins", default: [String]()) == ["c"])
  }

  @Test("A local edit replaces the list from before sync instead of merging it later")
  func editSupersedesUnmergedList() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    preferences.set(["a"], forKey: "pins")
    environment.syncClientPreferences(["pins"], preferences: preferences)

    preferences.set([String](), forKey: "pins")
    receive(environment, "pins", .array([.string("b")]))
    #expect(preferences.value(forKey: "pins", default: [String]()) == ["b"])
  }

  @Test("Editing a value this build cannot read keeps the edit on this device")
  func unreadableValuesAreNotOverwritten() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    environment.syncClientPreferences(["details"], preferences: preferences)
    receive(environment, "details", .array([.string("pr"), .string("status")]))
    #expect(preferences.value(forKey: "details", default: [Detail]()) == [])

    preferences.set([Detail.pr], forKey: "details")
    #expect(preferences.value(forKey: "details", default: [Detail]()) == [.pr])
    #expect(synced(environment, "details")?.value == .array([.string("pr"), .string("status")]))
  }
}
