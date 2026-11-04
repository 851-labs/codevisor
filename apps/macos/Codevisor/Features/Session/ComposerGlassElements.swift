import CodevisorUI

enum ComposerGlassElements {
  static func visible(
    hasTodos: Bool,
    showsGoal: Bool
  ) -> [ComposerGlassElement] {
    var elements: [ComposerGlassElement] = []
    if hasTodos {
      elements.append(.todos)
    }
    if showsGoal {
      elements.append(.goal)
    }
    elements.append(.composer)
    return elements
  }
}
