import Foundation

extension CloudAccountController {
  func redeemDevelopmentSignInTicket() async {
    guard let ticket = developmentSignInTicket,
      (try? FileManager.default.removeItem(at: ticket)) != nil
    else { return }
    await validation.task?.value
    guard state == .signedOut else { return }
    if !developmentAccountAvailable { await refreshAuthProviders() }
    await signInWithDevelopmentAccount()
  }
}
