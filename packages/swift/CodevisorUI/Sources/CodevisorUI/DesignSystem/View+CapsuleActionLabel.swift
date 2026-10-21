import SwiftUI

extension View {
  public func capsuleActionLabel() -> some View {
    font(.subheadline.weight(.medium))
      .padding(.horizontal, 12)
      .frame(minHeight: ComposerCardStyle.actionDiameter)
      .background(Capsule().fill(Color.secondary.opacity(0.16)))
      .expandedHitTarget(base: ComposerCardStyle.actionDiameter)
  }
}
