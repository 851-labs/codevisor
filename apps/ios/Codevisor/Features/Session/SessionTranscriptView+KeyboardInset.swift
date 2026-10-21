import SwiftUI

extension SessionTranscriptView {
  var keyboardInsetChat: some View {
    ZStack {
      Color.clear
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          keyboardAvoidingChatHeight = height
          adoptKeyboardOverlap(measuredKeyboardOverlap)
        }
        .background { ChatKeyboardInsetAnchor(inset: keyboardInset) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      Color.clear
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          keyboardFreeChatHeight = height
          adoptKeyboardOverlap(measuredKeyboardOverlap)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea(.keyboard)
      chatLayers
        .background { chatAreaExtentProbe }
        .padding(.bottom, keyboardOverlap)
        .background {
          ChatSurfaceBackground()
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
    }
  }

  var measuredKeyboardOverlap: CGFloat {
    max(0, keyboardFreeChatHeight - keyboardAvoidingChatHeight)
  }

  func adoptKeyboardOverlap(_ overlap: CGFloat) {
    guard keyboardFreeChatHeight > 0, keyboardAvoidingChatHeight > 0 else { return }
    let adoption = keyboardInset.adoption(of: overlap, from: keyboardOverlap) {
      adoptKeyboardOverlap(measuredKeyboardOverlap)
    }
    guard case let .apply(animated) = adoption, abs(overlap - keyboardOverlap) > 0.5 else { return }
    withAnimation(animated ? ChatKeyboardInset.animation : nil) {
      keyboardOverlap = overlap
    }
  }
}
