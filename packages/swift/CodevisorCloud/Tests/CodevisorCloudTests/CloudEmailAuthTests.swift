import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Native email authentication")
struct CloudEmailAuthTests {
  @Test("Signup waits for a code and never persists the password")
  func signup() async throws {
    let (cloud, client, store) = makeController()
    client.emailRequest = { request in
      switch request {
      case .signUp(email: "person@example.com", password: "test-password"): return nil
      case .verify(email: "person@example.com", code: "123456"): return "verified"
      default: throw CloudAccountClientError.invalidResponse
      }
    }
    client.sessions["verified"] = CloudSessionUser(userId: "person", email: "person@example.com")
    let model = CloudEmailAuthModel(cloud: cloud)
    model.navigate(to: .signUp)
    model.email = " Person@Example.com "
    model.password = "test-password"
    await model.submit()
    #expect(model.step == .verifyEmail)
    #expect(model.password.isEmpty)
    #expect(cloud.state == .signedOut)
    #expect(try store.token() == nil)
    model.code = "123456"
    await model.submit()
    #expect(model.isComplete)
    #expect(model.code.isEmpty)
    #expect(try store.token() == "verified")
    #expect(cloud.state == .signedIn(userEmail: "person@example.com"))
  }

  @Test("Verified email login uses only the password and registers the Mac")
  func login() async throws {
    let (cloud, client, store) = makeController()
    let local = FakeLocalServerClient()
    cloud.localServerClient = local
    client.emailRequest = { request in
      #expect(request == .signIn(email: "person@example.com", password: "test-password"))
      return "signed-in"
    }
    client.sessions["signed-in"] = CloudSessionUser(userId: "person", email: "person@example.com")
    let model = CloudEmailAuthModel(cloud: cloud)
    model.email = "person@example.com"
    model.password = "test-password"
    await model.submit()
    #expect(model.isComplete)
    #expect(try store.token() == "signed-in")
    #expect(local.connects.count == 1)
    #expect(model.password.isEmpty)
  }

  @Test("An unfinished signup resumes verification when logging in")
  func resumeVerification() async {
    let (cloud, client, _) = makeController()
    client.emailRequest = { request in
      switch request {
      case .signIn: throw CloudAccountClientError.emailNotVerified
      case .resendVerification(email: "person@example.com"): return nil
      default: throw CloudAccountClientError.invalidResponse
      }
    }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.email = "person@example.com"
    model.password = "test-password"
    await model.submit()
    #expect(model.step == .verifyEmail)
    #expect(model.errorMessage == nil)
    #expect(model.password.isEmpty)
    #expect(!model.isComplete)
  }

  @Test("Delivery failures preserve the verification form for resending")
  func deliveryFailure() async {
    let (cloud, client, _) = makeController()
    client.emailRequest = { _ in throw CloudAccountClientError.emailDeliveryFailed }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.navigate(to: .signUp)
    model.email = "person@example.com"
    model.password = "test-password"
    await model.submit()
    #expect(model.step == .verifyEmail)
    #expect(model.errorMessage == CloudAccountClientError.emailDeliveryFailed.localizedDescription)
    client.emailRequest = { request in
      #expect(request == .resendVerification(email: "person@example.com"))
      return nil
    }
    await model.resend()
    #expect(model.errorMessage == nil)
    #expect(model.notice != nil)
  }

  @Test("Reset uses email, code, and a new password, then returns to sign-in")
  func reset() async {
    let (cloud, client, _) = makeController()
    client.emailRequest = { request in
      switch request {
      case .requestPasswordReset(email: "person@example.com"): return nil
      case .resetPassword(email: "person@example.com", code: "654321", password: "new-password"): return nil
      default: throw CloudAccountClientError.invalidResponse
      }
    }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.navigate(to: .forgotPassword)
    model.email = "person@example.com"
    await model.submit()
    #expect(model.navigationPath == [.forgotPassword, .resetPassword])
    model.code = "654321"
    model.password = "new-password"
    await model.submit()
    #expect(model.navigationPath == [.passwordReset])
    #expect(model.password.isEmpty && model.code.isEmpty)
    await model.submit()
    #expect(model.navigationPath.isEmpty)
    #expect(model.email == "person@example.com")
  }

  @Test("Errors keep the form usable without adopting a session")
  func failure() async throws {
    let (cloud, client, store) = makeController()
    client.emailRequest = { _ in throw CloudAccountClientError.authenticationFailed("Incorrect password.") }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.email = "person@example.com"
    model.password = "incorrect"
    await model.submit()
    #expect(model.errorMessage == "Incorrect password.")
    #expect(!model.isBusy && model.canSubmit && !model.isComplete)
    #expect(try store.token() == nil)
  }

  @Test("Canceling an in-flight login cannot adopt its late session")
  func canceled() async throws {
    let (cloud, client, store) = makeController()
    let entered = TestSignal()
    let release = TestSignal()
    client.emailRequest = { _ in
      entered.signal()
      await release.wait()
      return "late-token"
    }
    let model = CloudEmailAuthModel(cloud: cloud)
    model.email = "person@example.com"
    model.password = "test-password"
    let task = Task { await model.submit() }
    await entered.wait()
    #expect(model.isBusy)
    task.cancel()
    model.cancel()
    release.signal()
    await task.value
    #expect(try store.token() == nil)
    #expect(model.password.isEmpty && !model.isComplete)
  }

  @Test("Server changes invalidate pending email authentication")
  func serverChange() async throws {
    let (cloud, client, store) = makeController()
    let entered = TestSignal()
    let release = TestSignal()
    client.emailRequest = { _ in
      entered.signal()
      await release.wait()
      return "wrong-server-token"
    }
    let context = try cloud.authenticationContext(link: false)
    let task = Task {
      try await cloud.authenticateEmail(.verify(email: "person@example.com", code: "123456"), context: context)
    }
    await entered.wait()
    try await cloud.setCustomServer(URL(string: "https://other.example"))
    release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try store.token() == nil)
  }
}
