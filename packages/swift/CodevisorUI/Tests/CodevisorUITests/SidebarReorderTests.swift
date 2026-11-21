import CodevisorCore
import CoreGraphics
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
struct SidebarReorderTests {
  private let atlas = UUID()
  private let scout = UUID()
  private let ledger = UUID()
  private let work = UUID()

  private func reorder() -> SidebarReorder<String> {
    let reorder = SidebarReorder<String>()
    for (index, row) in ["atlas", "work", "scout", "ledger"].enumerated() {
      reorder.frames[row] = CGRect(x: 0, y: CGFloat(index) * 40, width: 200, height: 40)
    }
    return reorder
  }

  private var region: SidebarDropRegion<String> {
    SidebarDropRegion(
      slots: [
        .item(atlas, row: "atlas", section: nil), .header("work", section: work),
        .item(scout, row: "scout", section: work), .item(ledger, row: "ledger", section: work),
      ], movesSections: true)
  }

  @Test("Dragging a lifted row past others drops it at the insertion line under the ghost")
  func dragToInsertion() {
    let reorder = reorder()
    reorder.liftItem(ledger, row: "ledger", in: region)
    reorder.drag(by: -100)

    #expect(reorder.isLifted("ledger"))
    #expect(reorder.ghostFrame == CGRect(x: 0, y: 20, width: 200, height: 40))
    #expect(reorder.insertionLine == CGRect(x: 0, y: 40, width: 200, height: 0))
    let drop = reorder.drop()
    #expect(drop?.lifted.row == "ledger")
    #expect(drop?.target == .item(.insertion(1)))
    #expect(reorder.lifted == nil)
    #expect(!reorder.allowsToggle)
  }

  @Test("Hovering another section's header targets the header and draws no line")
  func dragOntoHeader() {
    let reorder = reorder()
    reorder.liftItem(atlas, row: "atlas", in: region)
    reorder.drag(by: 40)

    #expect(reorder.isHeaderTarget(work))
    #expect(reorder.insertionLine == nil)
  }

  @Test("A drag that ends where it started, or a lift with no measured frame, commits nothing")
  func noOpDrags() {
    let reorder = reorder()
    reorder.liftItem(scout, row: "scout", in: region)
    reorder.drag(by: 5)
    #expect(reorder.drop() == nil)

    reorder.frames["scout"] = nil
    reorder.liftItem(scout, row: "scout", in: region)
    #expect(reorder.lifted == nil)
  }
}
