import SwiftUI

nonisolated struct WorkspaceSplitClip: Shape {
  let extendsAboveTop: Bool

  func path(in rect: CGRect) -> Path {
    guard extendsAboveTop else { return Path(rect) }
    return Path(CGRect(x: rect.minX, y: rect.minY - rect.height, width: rect.width, height: rect.height * 2))
  }
}
