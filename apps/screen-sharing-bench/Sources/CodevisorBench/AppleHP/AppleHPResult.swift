struct AppleHPResult: Encodable {
  let role = "apple-hp-viewer"
  let host: String
  let choseHighPerformance: Bool
  let focusLosses: Int
  let sessionOnScreen: Bool
  let window: WindowDescription
  let checkedMenuItems: [String]
  let controlMode: ControlMode
  let modeAtEnd: ControlMode
  let windowSharingStates: [Int]
}
