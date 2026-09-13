import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Email authentication navigation")
struct CloudEmailNavigationTests {
  @Test("Back from verification returns to signup with the email preserved")
  func backFromVerification() async {
    let (cloud, client, _) = makeController()
    client.emailRequest = { _ in nil }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.navigate(to: .signUp)
    model.email = "person@example.com"
    model.password = "test-password"
    await model.submit()
    #expect(model.navigationPath == [.signUp, .verifyEmail])
    await model.resend()
    model.code = "123456"
    model.setNavigationPath([.signUp])
    #expect(model.step == .signUp)
    #expect(model.email == "person@example.com")
    #expect(model.password.isEmpty && model.code.isEmpty && model.notice == nil)
    model.setNavigationPath([])
    #expect(model.step == .signIn)
  }

  @Test("Verification resumed from sign-in returns directly to sign-in")
  func resumedVerificationBack() async {
    let (cloud, client, _) = makeController()
    client.emailRequest = { request in
      if case .signIn = request { throw CloudAccountClientError.emailNotVerified }
      return nil
    }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.email = "person@example.com"
    model.password = "test-password"
    await model.submit()
    #expect(model.navigationPath == [.verifyEmail])
    model.setNavigationPath([])
    #expect(model.step == .signIn)
    #expect(model.email == "person@example.com")
  }

  @Test("Back cancels a request without disturbing a newer request")
  func backDuringRequest() async {
    let (cloud, client, _) = makeController()
    let firstEntered = TestSignal()
    let firstRelease = TestSignal()
    let nextEntered = TestSignal()
    let nextRelease = TestSignal()
    client.emailRequest = { request in
      if case .signUp = request {
        firstEntered.signal()
        await firstRelease.wait()
        throw CloudAccountClientError.emailDeliveryFailed
      }
      nextEntered.signal()
      await nextRelease.wait()
      return nil
    }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.navigate(to: .signUp)
    model.email = "person@example.com"
    model.password = "test-password"
    let first = Task { await model.submit() }
    await firstEntered.wait()
    first.cancel()
    model.setNavigationPath([])
    model.navigate(to: .forgotPassword)
    let next = Task { await model.submit() }
    await nextEntered.wait()
    firstRelease.signal()
    await first.value
    #expect(model.step == .forgotPassword)
    #expect(model.isBusy && model.errorMessage == nil)
    nextRelease.signal()
    await next.value
    #expect(model.navigationPath == [.forgotPassword, .resetPassword])
    model.code = "123456"
    model.password = "new-password"
    model.setNavigationPath([.forgotPassword])
    #expect(model.email == "person@example.com")
    #expect(model.password.isEmpty && model.code.isEmpty && !model.isBusy)
  }
}
