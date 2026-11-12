import SwiftUI

extension View {
  public func withoutAnimation(onChangeOf subject: some Equatable) -> some View {
    transaction(value: subject) { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }
}
