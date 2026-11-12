public enum ScreenSharingPreview: Equatable {
  case connecting
  case reconnecting
  case live(ScreenSharingViewerEndpoint)
  case failed(String)
}
