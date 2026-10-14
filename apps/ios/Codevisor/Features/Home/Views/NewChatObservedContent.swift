import SwiftUI

struct NewChatObservedContent: View {
  @Bindable var flow: NewChatFlow
  let content: (NewChatFlow) -> AnyView

  var body: some View {
    content(flow)
  }
}
