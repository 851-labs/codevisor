import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace sidebar manual order")
struct WorkspaceSidebarOrderTests {
  private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
  private let archived = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

  @Test func initialOrderIsPreserved() {
    let order = WorkspaceSidebarOrder([]).including([third, first, second])
    #expect(order.ids == [third, first, second])
  }

  @Test func chatChangesDoNotReorderExistingWorkspaces() {
    let order = WorkspaceSidebarOrder([first, second, third])
    #expect(order.applying(to: [third, second, first]) == [first, second, third])
  }

  @Test func newWorkspacesEnterAtTheTopOnce() {
    let order = WorkspaceSidebarOrder([first, second]).including([first, third, second])
    #expect(order.ids == [third, first, second])
    #expect(order.including([second, first, third]).ids == order.ids)
  }

  @Test func draggingMovesInBothDirections() {
    let visible = [first, second, third]
    let order = WorkspaceSidebarOrder(visible)
    #expect(order.moving(first, to: third, visibleIDs: visible).ids == [second, third, first])
    #expect(order.moving(third, to: first, visibleIDs: visible).ids == [third, first, second])
  }

  @Test func draggingPreservesArchivedAndOfflineSlots() {
    let order = WorkspaceSidebarOrder([first, archived, second, third])
    let moved = order.moving(third, to: first, visibleIDs: [first, second, third])
    #expect(moved.ids == [third, archived, first, second])
    #expect(moved.applying(to: [first, second, third]) == [third, first, second])
    #expect(moved.applying(to: [first, second, third, archived]) == moved.ids)
  }

  @Test func draggingBeforeANewWorkspaceHasBeenPersistedKeepsEveryRow() {
    let order = WorkspaceSidebarOrder([first, second])
    let moved = order.moving(third, to: second, visibleIDs: [third, first, second])
    #expect(moved.ids == [first, second, third])
  }

  @Test func duplicateAndMissingIDsCannotCorruptSavedOrder() {
    let order = WorkspaceSidebarOrder([first, first, second])
    #expect(order.ids == [first, second])
    #expect(order.including([third, third, first]).ids == [third, first, second])
    #expect(order.moving(third, to: first, visibleIDs: [first, second]).ids == order.ids)
    #expect(order.moving(first, to: first, visibleIDs: [first, second]).ids == order.ids)
  }
}
