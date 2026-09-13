import Foundation
import Testing
@testable import CodevisorCloud

@Suite("Email authentication requests")
struct CloudEmailClientTests {
  private let base = URL(string: "https://cloud.example")!

  @Test(
    "Credentials and codes use JSON POSTs to the selected server",
    arguments: [
      CloudEmailAuthRequest.signIn(email: "person@example.com", password: "test-password"),
      .signUp(email: "person@example.com", password: "test-password"),
      .verify(email: "person@example.com", code: "123456"),
      .resendVerification(email: "person@example.com"),
      .requestPasswordReset(email: "person@example.com"),
      .resetPassword(email: "person@example.com", code: "123456", password: "new-password"),
    ])
  func requests(operation: CloudEmailAuthRequest) async throws {
    let client = CloudAccountClient(baseURL: base) { request in
      let url = try #require(request.url)
      #expect(url.host == "cloud.example")
      #expect(url.query == nil)
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
      #expect(body["email"] == "person@example.com")
      switch operation {
      case .signIn:
        #expect(url.path == "/api/auth/sign-in/email" && body["password"] == "test-password")
      case .signUp:
        #expect(url.path == "/api/auth/sign-up/email" && body["name"] == "person")
      case .verify:
        #expect(url.path == "/api/auth/email-otp/verify-email" && body["otp"] == "123456")
      case .resendVerification:
        #expect(url.path == "/api/auth/email-otp/send-verification-otp" && body["type"] == "email-verification")
      case .requestPasswordReset:
        #expect(url.path == "/api/auth/email-otp/request-password-reset" && body.count == 1)
      case .resetPassword:
        #expect(url.path == "/api/auth/email-otp/reset-password" && body["password"] == "new-password")
        #expect(body["otp"] == "123456")
      }
      return (
        Data("{\"token\":\"body-token\"}".utf8),
        try #require(
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["set-auth-token": "header-token"])
        )
      )
    }
    let token = try await client.emailAuthentication(operation)
    #expect(token == (operation.returnsSession ? "header-token" : nil))
  }

  @Test("Signup cannot adopt an unexpected session token")
  func signupSession() async throws {
    let client = CloudAccountClient(baseURL: base) { request in
      let url = try #require(request.url)
      return (
        Data("{\"token\":\"unexpected\"}".utf8),
        try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      )
    }
    #expect(try await client.emailAuthentication(.signUp(email: "a@b.com", password: "password")) == nil)
  }

  @Test("Sign-in requires a session token")
  func missingToken() async throws {
    let client = CloudAccountClient(baseURL: base) { request in
      let url = try #require(request.url)
      return (
        Data("{}".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      )
    }
    await #expect(throws: CloudAccountClientError.missingToken) {
      try await client.emailAuthentication(.signIn(email: "a@b.com", password: "password"))
    }
  }

  @Test(
    "Server error codes become actionable native errors",
    arguments: [
      ("EMAIL_NOT_VERIFIED", 403, CloudAccountClientError.emailNotVerified),
      ("EMAIL_DELIVERY_FAILED", 503, .emailDeliveryFailed),
      (
        "INVALID_OTP", 400, .authenticationFailed("That code is incorrect or expired. Try again or request a new code.")
      ),
      ("RATE_LIMITED", 429, .authenticationFailed("Too many attempts. Please wait a minute and try again.")),
    ])
  func errors(code: String, status: Int, expected: CloudAccountClientError) async throws {
    let client = CloudAccountClient(baseURL: base) { request in
      let url = try #require(request.url)
      return (
        Data("{\"code\":\"\(code)\",\"message\":\"private provider detail\"}".utf8),
        try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
      )
    }
    await #expect(throws: expected) {
      try await client.emailAuthentication(.verify(email: "a@b.com", code: "123456"))
    }
  }
}
