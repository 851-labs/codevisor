import Testing

@testable import CodevisorClient

/// A server failure reads as its sentence, never as the JSON it arrived in (851-2391: the viewer
/// showed `{"error":"Open or update Codevisor on the host Mac, then retry Screen Sharing"}`).
struct CodevisorServerClientErrorTests {
  @Test func anErrorBodyShowsItsSentence() {
    let body = #"{"error":"Open or update Codevisor on the host Mac, then retry Screen Sharing"}"#
    #expect(
      CodevisorServerClientError.httpStatus(503, body).localizedDescription
        == "Open or update Codevisor on the host Mac, then retry Screen Sharing")
    #expect(
      CodevisorServerClientError.httpStatus(400, #"{"error":"Bad clone","code":"auth"}"#).localizedDescription
        == "Bad clone")
  }

  @Test func otherBodiesAreShownAsTheyAre() {
    #expect(CodevisorServerClientError.httpStatus(502, "Bad Gateway").localizedDescription == "Bad Gateway")
    #expect(CodevisorServerClientError.httpStatus(500, #"{"error":""}"#).localizedDescription == #"{"error":""}"#)
    #expect(CodevisorServerClientError.httpStatus(500, #"{"code":"x"}"#).localizedDescription == #"{"code":"x"}"#)
    #expect(
      CodevisorServerClientError.httpStatus(500, "").localizedDescription
        == "The Codevisor server rejected the request.")
  }
}
