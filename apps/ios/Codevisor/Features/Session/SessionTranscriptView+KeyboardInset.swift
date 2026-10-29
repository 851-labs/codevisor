import SwiftUI

extension SessionTranscriptView {
  var keyboardInsetChat: some View {
    Color.clear
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: { height in
        keyboardFreeChatHeight = height
        adoptKeyboardOverlap(measuredKeyboardOverlap, animated: false)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .overlay {
        chatLayers
          .background { chatAreaExtentProbe }
          .padding(.bottom, keyboardOverlap)
          .background {
            ChatSurfaceBackground()
              .ignoresSafeArea()
          }
      }
      .ignoresSafeArea(.keyboard)
      .background { keyboardAvoidingChatProbe }
  }

  var keyboardAvoidingChatProbe: some View {
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
  }

  var measuredKeyboardOverlap: CGFloat {
    max(0, keyboardFreeChatHeight - keyboardAvoidingChatHeight)
  }

  func adoptKeyboardOverlap(_ overlap: CGFloat, animated: Bool = true) {
    guard keyboardFreeChatHeight > 0, keyboardAvoidingChatHeight > 0 else { return }
    let adoption = keyboardInset.adoption(of: overlap, from: keyboardOverlap) {
      withAnimation(ChatKeyboardInset.animation) {
        adoptKeyboardOverlap(measuredKeyboardOverlap)
      }
    }
    guard case let .apply(adoptionAnimates) = adoption, abs(overlap - keyboardOverlap) > 0.5 else { return }
    if !animated || !adoptionAnimates {
      withAnimation(nil) { keyboardOverlap = overlap }
    } else if overlap > keyboardOverlap {
      keyboardOverlap = overlap
    } else {
      withAnimation(ChatKeyboardInset.animation) { keyboardOverlap = overlap }
    }
  }
}
