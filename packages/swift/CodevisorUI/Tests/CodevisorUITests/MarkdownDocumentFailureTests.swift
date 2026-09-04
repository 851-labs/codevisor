import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Markdown document error guidance")
struct MarkdownDocumentFailureTests {
  private let path = "/workspace/private/docs/missing.md"

  @Test func missingFileKeepsDiagnosticsOutOfMainMessage() {
    let error = CodevisorServerClientError.httpStatus(
      404, #"{"code":"not_found","error":"No such file: /workspace/private/docs/missing.md"}"#
    )
    let failure = MarkdownDocumentFailure(error: error, path: path)
    #expect(failure.title == "File not found")
    #expect(failure.message.contains("missing.md"))
    #expect(!failure.message.contains("/workspace"))
  }

  @Test func permissionAndAuthenticationHaveDifferentRecoveryGuidance() {
    let permission = MarkdownDocumentFailure(
      error: CodevisorServerClientError.httpStatus(403, "Permission denied"), path: path
    )
    let authentication = MarkdownDocumentFailure(
      error: CodevisorServerClientError.httpStatus(401, "Unauthorized"), path: path
    )
    #expect(permission.title == "Can’t access this file")
    #expect(authentication.title == "Connection needs attention")
    #expect(permission.message != authentication.message)
  }

  @Test func connectionFailuresDoNotClaimTheFileIsMissing() {
    for error: any Error in [
      URLError(.notConnectedToInternet),
      URLError(.timedOut),
      MachineUnreachableError(machineId: "remote"),
      ServerRequestGateError(message: "Server failed to start"),
    ] {
      let failure = MarkdownDocumentFailure(error: error, path: path)
      #expect(failure.title == "Can’t connect to this machine")
    }
  }

  @Test func unknownServerErrorsStayOutOfTheMessage() {
    let failure = MarkdownDocumentFailure(
      error: CodevisorServerClientError.httpStatus(500, "Internal diagnostic"), path: path
    )
    #expect(failure.title == "Can’t open this document")
    #expect(!failure.message.contains("Internal diagnostic"))
  }

  @Test func unreadableTextOffersEncodingGuidance() {
    let failure = MarkdownDocumentFailure(
      error: MarkdownDocumentLoadError.unsupportedEncoding, path: path
    )
    #expect(failure.title == "Can’t read this document")
    #expect(failure.message.contains("UTF-8"))
  }
}
