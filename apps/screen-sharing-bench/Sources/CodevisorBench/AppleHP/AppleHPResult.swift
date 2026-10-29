struct AppleHPResult: Encodable {
  let role = "apple-hp-viewer"
  let host: String
  let choseHighPerformance: Bool
  let window: WindowDescription
  let checkedMenuItems: [String]
}
