import CodevisorUI

enum ComposerGlassElements {
  static func visible(
    showsChildAgents: Bool,
    showsThreads: Bool = false,
    hasTodos: Bool,
    showsGoal: Bool
  ) -> [ComposerGlassElement] {
    var elements: [ComposerGlassElement] = []
    if showsChildAgents {
      elements.append(.childAgents)
    }
    if showsThreads {
      elements.append(.threads)
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
