import CodevisorCore
import SwiftUI

public struct SandboxSettingsPageView: View {
  let page: SandboxSettingsPage
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void

  public init(
    page: SandboxSettingsPage,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    navigate: @escaping (SandboxSettingsNavigation) -> Void
  ) {
    self.page = page
    self.model = model
    self.client = client
    self.navigate = navigate
  }

  public var body: some View {
    switch page {
    case let .editProfile(profileId):
      SandboxProfileRoute(profileId: profileId, model: model, client: client, navigate: navigate)
    }
  }
}
