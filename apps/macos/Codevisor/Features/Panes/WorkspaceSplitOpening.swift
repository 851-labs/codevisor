import CodevisorCore
import CodevisorUI
import Foundation

struct WorkspaceSplitOpening: Equatable, Identifiable {
  let id = UUID()
  let leafId: UUID
  let edge: SplitEdge
}
