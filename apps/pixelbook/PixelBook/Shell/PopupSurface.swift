import SwiftUI

extension View {
  func popupSurface() -> some View {
    glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
