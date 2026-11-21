struct FirstRunProgress: Comparable {
  let stage: Int
  let addedProjects: Int
  let answeredFolders: Int
  let answeredClaudeCodeLogin: Int

  static func < (left: Self, right: Self) -> Bool {
    (left.stage, left.addedProjects, left.answeredFolders, left.answeredClaudeCodeLogin)
      < (right.stage, right.addedProjects, right.answeredFolders, right.answeredClaudeCodeLogin)
  }
}
