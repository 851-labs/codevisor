struct EncodeLabFrameEvent: Sendable {
  let frame: Int
  let version: Int
  let tick: Int
  let scheduledNs: Int64
  let preparedNs: Int64
  let submittedNs: Int64
  let returnedNs: Int64
  let encodedTiles: [Int]
  let dirtyTiles: Int
  let refresh: EncodeLabRefresh?
  let repeats: Bool
}
