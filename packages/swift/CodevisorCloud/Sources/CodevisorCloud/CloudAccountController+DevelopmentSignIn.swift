import Foundation

extension CloudAccountController {
  func redeemDevelopmentSignInTicket() async {
    guard let ticket = developmentSignInTicket,
      (try? FileManager.default.removeItem(at: ticket)) != nil,
      state == .signedOut
    else { return }
    await signInWithDevelopmentAccount()
  }
}
