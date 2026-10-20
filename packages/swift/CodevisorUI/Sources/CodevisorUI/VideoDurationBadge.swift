import SwiftUI

public struct VideoDurationBadge: View {
  let seconds: Double

  public init(seconds: Double) {
    self.seconds = seconds
  }

  public var body: some View {
    Text(Self.label(seconds: seconds))
      .font(.system(size: 10, weight: .semibold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Capsule().fill(.black.opacity(0.6)))
      .allowsHitTesting(false)
  }

  static func label(seconds: Double) -> String {
    let total = max(Int(seconds.rounded()), 0)
    let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }
}
