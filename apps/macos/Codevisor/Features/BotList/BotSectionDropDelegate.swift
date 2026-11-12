import CodevisorUI
import SwiftUI

struct BotSectionDropDelegate: DropDelegate {
  let target: UUID
  @Binding var dragging: UUID?
  @Binding var dropTarget: UUID?
  let perform: (() -> Void)?

  func validateDrop(info: DropInfo) -> Bool {
    dragging != nil && perform != nil
  }

  func dropEntered(info: DropInfo) {
    dropTarget = target
  }

  func dropExited(info: DropInfo) {
    if dropTarget == target { dropTarget = nil }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    perform?()
    dragging = nil
    dropTarget = nil
    return true
  }
}
