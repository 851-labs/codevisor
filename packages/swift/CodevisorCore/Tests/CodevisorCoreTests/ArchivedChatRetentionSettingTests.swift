import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Archived chat retention setting")
struct ArchivedChatRetentionSettingTests {
  private func makeSync() -> ConfigSync {
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    return ConfigSync(machines: controller, store: InMemoryStore())
  }

  @Test("Archived chats are deleted after 30 days until someone chooses otherwise")
  func defaultsToThirtyDays() {
    let setting = ArchivedChatRetentionSetting(configSync: makeSync())

    #expect(setting.current == .thirtyDays)
  }

  @Test("A choice is synced in the form every server reads")
  func choiceSyncsForServers() {
    let sync = makeSync()
    let setting = ArchivedChatRetentionSetting(configSync: sync)

    setting.choose(.sevenDays)

    #expect(setting.current == .sevenDays)
    #expect(sync.value(namespace: "settings", key: "archivedChatRetention") == .string("7-days"))
  }

  @Test("An unknown synced value falls back to 30 days")
  func unknownValueFallsBack() {
    let sync = makeSync()
    sync.set(namespace: "settings", key: "archivedChatRetention", value: .string("forever-ish"))

    #expect(ArchivedChatRetentionSetting(configSync: sync).current == .thirtyDays)
  }
}
