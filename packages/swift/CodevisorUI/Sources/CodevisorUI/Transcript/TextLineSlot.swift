import SwiftUI

struct TextLineSlot<Content: View>: View {
  let width: CGFloat
  @ViewBuilder let content: () -> Content

  var body: some View {
    Text(" ")
      .hidden()
      .frame(width: width)
      .overlay(content: content)
  }
}
