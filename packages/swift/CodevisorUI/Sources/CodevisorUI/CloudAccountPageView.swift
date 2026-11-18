import CodevisorCore
import SwiftUI

public struct CloudAccountPageView: View {
  private let page: CloudAccountPage
  private let cloud: CloudAccountController

  public init(_ page: CloudAccountPage, cloud: CloudAccountController) {
    self.page = page
    self.cloud = cloud
  }

  public var body: some View {
    switch page {
    case .connectedAccounts: CloudConnectedAccountsSettings(cloud: cloud)
    case .server: CloudServerSettings(cloud: cloud)
    }
  }
}
