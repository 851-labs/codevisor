public enum BenchTestCard: Int, CaseIterable, Sendable {
  case textLight
  case textDark
  case chroma
  case photo

  public static func shown(atVersion version: Int) -> BenchTestCard {
    allCases[version % allCases.count]
  }
}
