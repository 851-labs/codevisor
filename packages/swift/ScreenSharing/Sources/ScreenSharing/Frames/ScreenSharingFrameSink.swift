public protocol ScreenSharingFrameSink: Sendable {
  func push(_ frame: ScreenSharingVideoFrame)
}
