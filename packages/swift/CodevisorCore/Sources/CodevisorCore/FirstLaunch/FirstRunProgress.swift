struct FirstRunProgress: Comparable {
  let stage: Int
  let addedProjects: Int
  let answeredFolders: Int

  static func < (left: Self, right: Self) -> Bool {
    (left.stage, left.addedProjects, left.answeredFolders) < (right.stage, right.addedProjects, right.answeredFolders)
  }
}
