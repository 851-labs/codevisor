struct EncodeLabRefinementCap {
  static let unrestrictedQP = 51

  private let refineQP: Int?
  private let changeQP: Int
  private var appliedQP: Int

  init(config: EncodeLabConfig) {
    refineQP = config.refineQP
    changeQP = config.maxQP ?? Self.unrestrictedQP
    appliedQP = changeQP
  }

  mutating func change(repeats: Bool) -> Int? {
    guard let refineQP else { return nil }

    let wanted = repeats ? refineQP : changeQP
    guard wanted != appliedQP else { return nil }

    appliedQP = wanted
    return wanted
  }
}
