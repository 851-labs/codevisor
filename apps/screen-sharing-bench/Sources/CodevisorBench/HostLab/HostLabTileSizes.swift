import ScreenSharingV2

struct HostLabTileSizes: Codable, Equatable, Sendable {
  struct Pass: Codable, Equatable, Sendable {
    let pass: Int
    let count: Int
    let meanBytes: Int
    let p50Bytes: Int
  }

  private var passSinceChange: [Int: Int] = [:]
  private var bytesByPass: [Int: [Int]] = [:]

  init() {}

  mutating func record(tile: Int, isRefinement: Bool, bytes: Int) {
    let pass = isRefinement ? (passSinceChange[tile] ?? 0) + 1 : 0
    passSinceChange[tile] = pass
    bytesByPass[pass, default: []].append(bytes)
  }

  var passes: [Pass] {
    bytesByPass.keys.sorted().compactMap { pass in
      guard let sizes = bytesByPass[pass]?.sorted(), !sizes.isEmpty else { return nil }

      return Pass(
        pass: pass, count: sizes.count, meanBytes: sizes.reduce(0, +) / sizes.count, p50Bytes: sizes[sizes.count / 2])
    }
  }
}
