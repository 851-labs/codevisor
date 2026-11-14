struct ScreenSharingOnScreenState: Equatable {
  var isInWindow = false
  var sceneIsActive = false
  var hasSize = false

  var isOnScreen: Bool { isInWindow && sceneIsActive && hasSize }

  mutating func change(_ update: (inout Self) -> Void) -> Bool? {
    let before = isOnScreen
    update(&self)
    return isOnScreen == before ? nil : isOnScreen
  }
}
