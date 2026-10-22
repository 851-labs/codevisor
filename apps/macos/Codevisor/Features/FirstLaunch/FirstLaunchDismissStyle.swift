import CodevisorClient
import Foundation
import SwiftUI

enum FirstLaunchDismissStyle: String, CaseIterable {
  case crossfade
  case flyIntoComposer
  case rowsIntoChips
  case iconZoom
  case glassMorph

  static func current(reduceMotion: Bool) -> FirstLaunchDismissStyle {
    guard !reduceMotion else { return .crossfade }
    return developmentOverride ?? .crossfade
  }

  var animation: Animation {
    switch self {
    case .crossfade: .smooth(duration: 0.35)
    case .flyIntoComposer: .smooth(duration: 0.65)
    case .rowsIntoChips: .smooth(duration: 0.65)
    case .iconZoom: .easeIn(duration: 0.55)
    case .glassMorph: .spring(duration: 0.6, bounce: 0.12)
    }
  }

  private static var developmentOverride: FirstLaunchDismissStyle? {
    guard CodevisorAppVariant.isDevelopment,
      let raw = ProcessInfo.processInfo.environment["CODEVISOR_DEV_FIRST_LAUNCH_DISMISS"]
    else { return nil }
    return FirstLaunchDismissStyle(rawValue: raw)
  }
}
