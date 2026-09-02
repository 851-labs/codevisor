import SwiftUI

/// Keeps the `UIHostingController` root structurally stable while still
/// allowing promotion state to re-render the sheet's SwiftUI content. UIKit
/// navigation bars can lose their toolbar registrations when a hosting
/// controller's type-erased root is reassigned during an active transition.
struct NewChatObservedContent: View {
  @Bindable var flow: NewChatFlow
  let content: (NewChatFlow) -> AnyView

  var body: some View {
    content(flow)
  }
}
