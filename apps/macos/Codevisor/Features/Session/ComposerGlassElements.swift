import CodevisorUI

enum ComposerGlassElements {
  static func visible(
    showsChildAgents: Bool,
    hasTodos: Bool,
    showsGoal: Bool
  ) -> [ComposerGlassElement] {
    var elements: [ComposerGlassElement] = []
    if showsChildAgents {
      elements.append(.childAgents)
    }
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
