public enum BenchScene: String, CaseIterable, Sendable, Codable {
  case idleCursor = "idle-cursor"
  case typing
  case scroll
  case windowDrag = "window-drag"
  case video
  case testCards = "test-cards"
  case input

  public var timeline: BenchSceneTimeline {
    switch self {
    case .idleCursor: .everyTicks(BenchSceneTiming.caretToggleTicks)
    case .typing: .typing
    case .scroll, .windowDrag, .video: .everyTick
    case .testCards: .everyTicks(BenchSceneTiming.cardTicks)
    case .input: .inputDriven
    }
  }
}
