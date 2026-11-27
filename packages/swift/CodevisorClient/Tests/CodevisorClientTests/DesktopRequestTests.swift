import Foundation
import Testing

@testable import CodevisorClient

struct DesktopRequestTests {
  @Test("Each desktop call is one request to the route the command line uses")
  func routes() async throws {
    let transport = DesktopTransport()
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    _ = try await client.desktopStatus()
    _ = try await client.installDesktopPackages()
    _ = try await client.replaceOldDesktop()
    _ = try await client.startDesktop(replacingUnmanaged: false)
    _ = try await client.startDesktop(replacingUnmanaged: true)
    _ = try await client.removeDesktop(unsharingUnmanaged: false)
    _ = try await client.removeDesktop(unsharingUnmanaged: true)
    let sent = await transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")?\($0.url?.query ?? "")" }
    #expect(
      sent == [
        "GET /v1/desktop?", "POST /v1/desktop/packages?", "POST /v1/desktop/replace-old?",
        "POST /v1/desktop/start?", "POST /v1/desktop/start?replace=1", "DELETE /v1/desktop?",
        "DELETE /v1/desktop?unshare=1",
      ])
  }

  @Test("The status reads what the server sends, with what it leaves out as nil")
  func decoding() async throws {
    let client = CodevisorServerClient(config: .init(requestTransport: DesktopTransport()))
    let status = try await client.desktopStatus()
    #expect(
      status
        == ServerDesktopStatus(
          state: .stopped, account: "codevisor", system: "Ubuntu 24.04.5 LTS",
          problem: "the desktop's session isn't up", missing: ["xclip"], packageManager: "apt",
          sudo: .password, oldDesktop: .init(units: ["vncserver@1.service"]),
          logHint: "journalctl --user -u codevisor-desktop"))
  }
}

private actor DesktopTransport: ServerRequestTransport {
  var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body = """
      {"state":"stopped","account":"codevisor","system":"Ubuntu 24.04.5 LTS","display":1,
       "problem":"the desktop's session isn't up","missing":["xclip"],"packageManager":"apt",
       "sudo":"password","oldDesktop":{"units":["vncserver@1.service"]},"startsAtBoot":false,
       "logHint":"journalctl --user -u codevisor-desktop","somethingNewer":true}
      """
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
