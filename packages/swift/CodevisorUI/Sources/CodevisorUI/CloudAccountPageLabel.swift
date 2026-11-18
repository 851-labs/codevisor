import CodevisorCore
import SwiftUI

public struct CloudAccountPageLabel: View {
  private let page: CloudAccountPage
  private let cloud: CloudAccountController

  public init(_ page: CloudAccountPage, cloud: CloudAccountController) {
    self.page = page
    self.cloud = cloud
  }

  public var body: some View {
    HStack {
      switch page {
      case .connectedAccounts:
        Label("Connected Accounts", systemImage: "person.crop.circle.badge.checkmark")
        Spacer()
      case .server:
        Label("Cloud Server", systemImage: "network")
        Spacer()
        Text(cloud.customServerURL == nil ? "Default" : "Custom")
          .foregroundStyle(.secondary)
      }
    }
  }
}
