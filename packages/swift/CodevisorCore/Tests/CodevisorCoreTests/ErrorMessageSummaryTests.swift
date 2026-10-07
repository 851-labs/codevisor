import Testing

@testable import CodevisorCore

@Suite("Error message summaries")
struct ErrorMessageSummaryTests {
  @Test("A short error is shown as it is, with nothing more to show")
  func short() {
    let error = ErrorMessageSummary("  Sign-in failed.  ")
    #expect(error.summary == "Sign-in failed.")
    #expect(error.details == nil)
  }

  @Test("A dumped value is cut off, with the label that introduced it")
  func dump() {
    let message = """
      Internal error: Type validation failed: Value: {"id":"32b8","choices":[]}.
      Error message: [
        { "code": "invalid_union" }
      ]
      """
    let error = ErrorMessageSummary(message)
    #expect(error.summary == "Internal error: Type validation failed")
    #expect(error.details == message)
    // A label of several words is part of the sentence, so it stays.
    #expect(ErrorMessageSummary(#"Request failed with body: {"a":1}"#).summary == "Request failed with body")
    #expect(ErrorMessageSummary(#"Provider said {"a":1}"#).summary == "Provider said")
  }

  @Test("Only the first line leads, without its closing punctuation")
  func lines() {
    let error = ErrorMessageSummary("Rate limited.\nRetry after 30 seconds")
    #expect(error.summary == "Rate limited")
    #expect(error.details == "Rate limited.\nRetry after 30 seconds")
  }

  @Test("A message that starts with its dump, or runs long, is capped to a line")
  func capped() {
    let dump = ErrorMessageSummary(#"{"error":"bad"}"#)
    #expect(dump.summary == #"{"error":"bad"}"#)
    #expect(dump.details == nil)
    let long = String(repeating: "word ", count: 50)
    let error = ErrorMessageSummary(long)
    #expect(error.summary.count == ErrorMessageSummary.maximumLength)
    #expect(error.summary.hasSuffix("…"))
    #expect(error.details == long.trimmingCharacters(in: .whitespaces))
  }
}
