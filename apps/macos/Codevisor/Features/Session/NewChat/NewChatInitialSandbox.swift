import SwiftUI

struct NewChatInitialSandbox: ViewModifier {
  struct Request: Equatable {
    let profileId: String?
    let isChoosable: Bool
  }

  let request: Request
  let choose: (String) -> Void
  @State private var appliedProfileId: String?

  func body(content: Content) -> some View {
    content.onChange(of: request, initial: true) { _, request in apply(request) }
  }

  private func apply(_ request: Request) {
    guard let profileId = request.profileId else {
      appliedProfileId = nil
      return
    }
    guard request.isChoosable, appliedProfileId != profileId else { return }

    appliedProfileId = profileId
    choose(profileId)
  }
}
