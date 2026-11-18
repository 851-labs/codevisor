import SwiftUI

public struct CloudAccountPageLabel: View {
  private let page: CloudAccountPage

  public init(_ page: CloudAccountPage) {
    self.page = page
  }

  public var body: some View {
    HStack {
      switch page {
      case .connectedAccounts:
        Label("Connected Accounts", systemImage: "person.crop.circle.badge.checkmark")
      }
      Spacer()
    }
  }
}
