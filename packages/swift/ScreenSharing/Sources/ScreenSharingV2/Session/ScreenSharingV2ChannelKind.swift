enum ScreenSharingV2ChannelKind: UInt8, CaseIterable, Sendable {
  case control = 1
  case clipboard = 2
  case clipboardSharing = 3
  case display = 4
  case videoFormat = 5
  case cursor = 6
  case audio = 7
}
