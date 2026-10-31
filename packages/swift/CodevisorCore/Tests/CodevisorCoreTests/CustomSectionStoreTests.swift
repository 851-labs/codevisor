import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("CustomSectionStore")
struct CustomSectionStoreTests {
  @MainActor
  private struct Mac {
    let environment = AppEnvironment.preview()

    var store: CustomSectionStore { environment.botSections }

    func receive(from other: Mac) {
      environment.configSync.applyRemoteChange(
        namespace: CustomSectionStore.botNamespace,
        entries: other.environment.configSync.entries(namespace: CustomSectionStore.botNamespace))
    }
  }

  private func exchange(_ first: Mac, _ second: Mac) {
    first.receive(from: second)
    second.receive(from: first)
  }

  @Test("New sections go to the end, and a moved section lands at its new index")
  func ordering() {
    let mac = Mac()
    let work = mac.store.create(name: "Work")
    let home = mac.store.create(name: "Home")
    let ops = mac.store.create(name: "Ops")

    mac.store.moveSection(ops.id, toIndex: 0)
    #expect(mac.store.sections.map(\.name) == ["Ops", "Work", "Home"])

    mac.store.moveSection(ops.id, toIndex: 2)
    mac.store.rename(home.id, to: "Personal")
    #expect(mac.store.sections.map(\.name) == ["Work", "Personal", "Ops"])
    #expect(mac.store.sections.map(\.id) == [work.id, home.id, ops.id])
  }

  @Test("Deleting a section sends its bots to the default list, even one another Mac moved in meanwhile")
  func deleteWinsOverConcurrentMove() {
    let (first, second) = (Mac(), Mac())
    let (moved, kept) = (UUID(), UUID())
    let work = first.store.create(name: "Work")
    first.store.move(kept, to: work.id)
    exchange(first, second)

    second.store.move(moved, to: work.id)
    first.store.delete(work.id)
    exchange(first, second)

    for mac in [first, second] {
      #expect(mac.store.sections.isEmpty)
      #expect(mac.store.membership.isEmpty)
    }
  }

  @Test("Edits to different sections and bots merge across Macs; the later write to one section wins")
  func perEntityMerge() {
    let (first, second) = (Mac(), Mac())
    let bot = UUID()
    let work = first.store.create(name: "Work")
    let home = first.store.create(name: "Home")
    exchange(first, second)

    first.store.rename(work.id, to: "Office")
    second.store.move(bot, to: home.id)
    exchange(first, second)
    second.store.rename(work.id, to: "Day job")
    exchange(first, second)

    for mac in [first, second] {
      #expect(mac.store.sections.map(\.name) == ["Day job", "Home"])
      #expect(mac.store.membership == [bot: home.id])
    }
  }

  @Test("Entries this version can't read are ignored instead of breaking the list")
  func malformedEntriesAreIgnored() {
    let mac = Mac()
    let work = mac.store.create(name: "Work")
    mac.environment.configSync.set(
      namespace: CustomSectionStore.botNamespace, key: "section:not-a-uuid", value: .object(["name": .string("?")]))
    mac.environment.configSync.set(
      namespace: CustomSectionStore.botNamespace, key: "member:\(UUID().uuidString)", value: .string("Work"))

    #expect(mac.store.sections.map(\.id) == [work.id])
    #expect(mac.store.membership.isEmpty)
  }
}
