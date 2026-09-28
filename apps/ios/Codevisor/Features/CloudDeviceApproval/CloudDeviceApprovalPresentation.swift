import SwiftUI

/// Presents a scanned device-approval request. Applied twice — to Home and
/// to the onboarding cover — because a sheet attached under a full-screen
/// cover can't show. The request latched which context was visible when it
/// arrived, so it presents in exactly one place, and Home keeps that cover
/// up until the sheet is dismissed.
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
