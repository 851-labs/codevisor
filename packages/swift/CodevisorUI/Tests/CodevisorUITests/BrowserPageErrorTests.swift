import Testing
@testable import CodevisorUI

@Suite("Browser page errors")
struct BrowserPageErrorTests {
  private func error(_ code: Int, proxyFailure: String? = nil) -> BrowserPageError {
    .load(
      code: code, description: "ERR_SOMETHING", url: "https://example.com/path", machine: "Studio",
      proxyFailure: proxyFailure)
  }

  @Test func namesTheFailureInsteadOfShowingChromiumCodes() {
    #expect(error(-105).title == "Can’t Find Server")
    #expect(error(-105).message == "Studio couldn’t find example.com.")
    #expect(error(-102).message == "example.com refused to connect.")
    #expect(error(-118).title == "Server Not Responding")
    #expect(error(-130).title == "Can’t Reach Studio")
    #expect(error(-106).title == "You’re Offline")
    #expect(error(-310).title == "Too Many Redirects")
    #expect(error(-312).message == "Browsers block this port for security.")
    #expect(error(-1).message == "Studio couldn’t load example.com. ERR_SOMETHING")
    #expect(error(-1).url == "https://example.com/path")
  }

  @Test func explainsCertificateProblems() {
    #expect(error(-202).title == "Connection Not Private")
    #expect(error(-202).systemImage == "lock.slash")
    #expect(error(-201).message == "The certificate for example.com has expired or isn’t valid yet.")
    #expect(error(-213).message == "The certificate for example.com isn’t valid.")
  }

  @Test func usesTheMachinesReasonForProxiedFailures() {
    #expect(BrowserPageError.needsProxyDiagnosis(code: -111))
    #expect(!BrowserPageError.needsProxyDiagnosis(code: -105))
    #expect(error(-111, proxyFailure: "dns").title == "Can’t Find Server")
    #expect(error(-111, proxyFailure: "timeout").title == "Server Not Responding")
    #expect(error(-111).message == "Studio couldn’t connect to example.com.")
    #expect(error(-379).title == "Page Isn’t Working")
    #expect(error(-379, proxyFailure: "refused").message == "example.com refused to connect.")
  }
}
