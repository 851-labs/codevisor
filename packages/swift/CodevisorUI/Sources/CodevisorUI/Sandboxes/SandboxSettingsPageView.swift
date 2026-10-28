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
    case .addProfile:
      SandboxProviderChoicePage(model: model, navigate: navigate)
    case .vendors:
      SandboxVendorChoicePage(model: model, navigate: navigate)
    case let .newProvider(vendorId):
      if let vendor = model.vendor(vendorId) {
        SandboxNewProviderPage(vendor: vendor, model: model, client: client, navigate: navigate)
      }
    case let .newProfile(providerId):
      if let provider = model.provider(providerId), let vendor = model.vendor(provider.vendor) {
        SandboxNewProfilePage(provider: provider, vendor: vendor, model: model, client: client, navigate: navigate)
      }
    case let .editProfile(profileId):
      if let profile = model.profile(profileId) {
        SandboxEditProfilePage(profile: profile, model: model, client: client, navigate: navigate)
      }
    case let .editProvider(providerId):
      if let provider = model.provider(providerId), let vendor = model.vendor(provider.vendor) {
        SandboxEditProviderPage(provider: provider, vendor: vendor, model: model, client: client, navigate: navigate)
      }
    }
  }
}
