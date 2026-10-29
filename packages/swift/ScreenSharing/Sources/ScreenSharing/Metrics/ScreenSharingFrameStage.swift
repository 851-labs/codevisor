public enum ScreenSharingFrameStage: String, CaseIterable, Codable, Sendable {
  case capture
  case hostQueue
  case encode
  case network
  case jitterBuffer
  case decode
  case delivery
  case renderQueue
  case present
}
