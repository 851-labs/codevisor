import CodevisorCore
import SwiftUI

struct SandboxProfileRoute: View {
  let profileId: String
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var lastShown: ServerSandboxProfile?

  var body: some View {
    if let profile = model.profile(profileId) ?? lastShown {
      SandboxProfilePage(profile: profile, model: model, client: client, navigate: navigate)
        .onAppear { lastShown = profile }
    }
  }
}
