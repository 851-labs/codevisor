enum FirstLaunchOverlayPhase {
  case covering
  case morphing
  case revealing
  case crossfading
  case gone

  var coversApp: Bool {
    self == .covering || self == .morphing
  }

  var isLeaving: Bool {
    self == .morphing || self == .revealing || self == .crossfading
  }
}
