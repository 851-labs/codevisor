struct FirstRunProgress: Comparable {
  let stage: Int
  let addedProjects: Int

  static func < (left: Self, right: Self) -> Bool {
    (left.stage, left.addedProjects) < (right.stage, right.addedProjects)
  }
}
