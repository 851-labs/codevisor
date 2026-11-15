import Foundation

@MainActor
final class ScreenSharingPaneWorkspace {
  var id: UUID?

  init(_ id: UUID?) {
    self.id = id
  }
}
