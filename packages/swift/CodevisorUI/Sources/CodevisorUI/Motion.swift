import SwiftUI

public enum Motion {
  public static let splitDuration = 0.22

  public static let listReflowDuration = 0.2

  public static func entrance(reduceMotion: Bool = false) -> Animation? {
    reduceMotion ? nil : .smooth(duration: 0.2)
  }

  public static func indicator(reduceMotion: Bool = false) -> Animation? {
    reduceMotion ? nil : .smooth(duration: 0.16)
  }

  public static func quick(reduceMotion: Bool = false) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.2)
  }

  public static func listReflow(reduceMotion: Bool = false) -> Animation? {
    reduceMotion ? nil : .smooth(duration: listReflowDuration)
  }

  public static func panel(reduceMotion: Bool = false) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.25)
  }

  public static func split(reduceMotion: Bool = false) -> Animation? {
    reduceMotion ? nil : .smooth(duration: splitDuration)
  }

  public static func unfold(reduceMotion: Bool = false, anchor: UnitPoint = .top) -> AnyTransition {
    reduceMotion
      ? .opacity
      : .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
  }

  public static func pop(reduceMotion: Bool = false) -> AnyTransition {
    reduceMotion
      ? .opacity
      : .opacity.combined(with: .scale(scale: 0.85))
  }
}
