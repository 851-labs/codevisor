import Foundation

@MainActor
struct ScreenSharingDesktopSurfaceEvents {
  var pictureChanged: @MainActor () -> Void
  var focusChanged: @MainActor (Bool) -> Void
  var keyboardReturned: @MainActor () -> Void
}
