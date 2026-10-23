import SwiftUI

struct FirstLaunchCardGlass: View {
  let shape: FirstLaunchGlassShape

  var body: some View {
    Color.clear
      .frame(width: shape.size?.width, height: shape.size?.height)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: shape.cornerRadius))
      .offset(shape.offset)
      .opacity(shape.opacity)
  }
}
