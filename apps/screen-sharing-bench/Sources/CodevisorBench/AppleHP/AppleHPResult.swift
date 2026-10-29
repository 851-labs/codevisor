struct AppleHPResult: Encodable {
  let role = "apple-hp-viewer"
  let host: String
  let window: WindowDescription
  let checkedMenuItems: [String]
}
