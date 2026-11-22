import Foundation
import Testing

@testable import CodevisorCore

@Suite("DiagnosticsScrubber")
struct DiagnosticsScrubberTests {
  @Test(
    "Removes paths, emails, and secrets while keeping the error's wording",
    arguments: [
      ("Couldn't open /Users/someone/code/secret-project/main.swift", "Couldn't open <path>"),
      ("git failed in ~/work/acme-repo: not a repository", "git failed in <path>: not a repository"),
      ("permission denied: /home/dev/.config/app.json", "permission denied: <path>"),
      ("contact person@example.com for access", "contact <email> for access"),
      ("401 with Bearer abc.def-123", "401 with Bearer <redacted>"),
      ("token sk-ant-api03-AbCdEf leaked", "token <redacted> leaked"),
      ("push rejected ghp_0123456789abcdefABCDEF", "push rejected <redacted>"),
      ("api_key=12345 rejected", "api_key=<redacted> rejected"),
      ("GET https://api.example.com/v1/models returned 500", "GET https://api.example.com/v1/models returned 500"),
    ]
  )
  func scrubs(input: String, expected: String) {
    #expect(DiagnosticsScrubber.scrub(input) == expected)
  }

  @Test("Removes the signed-in macOS user's name")
  func removesUserName() {
    let name = NSUserName()
    #expect(DiagnosticsScrubber.scrub("owner \(name) lacks access") == "owner <user> lacks access")
  }

  @Test("Caps long messages")
  func capsLength() {
    let long = String(repeating: "x", count: DiagnosticsScrubber.maxLength * 2)
    #expect(DiagnosticsScrubber.scrub(long).count == DiagnosticsScrubber.maxLength)
  }
}
