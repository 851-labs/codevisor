import SwiftUI

struct CloudDeviceApprovalPresentation: ViewModifier {
  @Binding var pending: CloudDeviceApprovalRequest?
  let hostedByOnboarding: Bool

  func body(content: Content) -> some View {
    content
      .sheet(
        item: Binding(
          get: { pending?.presentsOverOnboarding == hostedByOnboarding ? pending : nil },
          set: { if $0 == nil { pending = nil } }
        )
      ) { request in
        CloudDeviceApprovalSheet(request: request)
      }
  }
}
