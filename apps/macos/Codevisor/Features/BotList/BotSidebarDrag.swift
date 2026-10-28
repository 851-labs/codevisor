import CodevisorUI
import SwiftUI

enum BotSidebarDrag: Equatable {
  case bot(UUID)
  case section(UUID)

  var itemProvider: NSItemProvider {
    switch self {
    case let .bot(id), let .section(id): NSItemProvider(object: id.uuidString as NSString)
    }
  }
}

struct BotSidebarDropDelegate: DropDelegate {
  let target: BotSidebarRowID
  @Binding var drag: BotSidebarDrag?
  @Binding var dropTarget: BotSidebarRowID?
  let perform: (() -> Void)?

  func validateDrop(info: DropInfo) -> Bool {
    drag != nil && perform != nil
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
    drag = nil
    dropTarget = nil
    return true
  }
}
