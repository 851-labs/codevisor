public enum BenchSceneResolution: String, CaseIterable, Sendable {
  case r1 = "R1"
  case r1HiDPI = "R1x2"
  case r2 = "R2"
  case r3 = "R3"

  public var pointWidth: Int {
    switch self {
    case .r1, .r1HiDPI: 1920
    case .r2: 2560
    case .r3: 3840
    }
  }

  public var pointHeight: Int {
    switch self {
    case .r1, .r1HiDPI: 1080
    case .r2: 1440
    case .r3: 2160
    }
  }

  public var scale: Int {
    switch self {
    case .r1, .r3: 1
    case .r1HiDPI, .r2: 2
    }
  }
}
