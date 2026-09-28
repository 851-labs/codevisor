import Foundation
import Testing
@testable import CodevisorCloud

@Suite("Device approval links")
struct CloudDeviceApprovalLinkTests {
  @Test("Parses the verification page link into its cloud origin and code")
  func parsesVerificationLinks() throws {
    let hosted = try #require(
      CloudDeviceApprovalLink.parse(URL(string: "https://cloud.codevisor.dev/device?user_code=ABCD-EFGH")!))
    #expect(hosted.serverURL == URL(string: "https://cloud.codevisor.dev")!)
    #expect(hosted.userCode == "ABCD-EFGH")
    #expect(hosted.host == "cloud.codevisor.dev")

    let custom = try #require(
      CloudDeviceApprovalLink.parse(URL(string: "https://Cloud.Example.com:8443/device/?user_code=%20WXYZ1234%20")!))
    #expect(custom.serverURL == URL(string: "https://cloud.example.com:8443")!)
    #expect(custom.userCode == "WXYZ1234")
    #expect(custom.host == "cloud.example.com:8443")

    // The local dev cloud is a plain-http Worker on loopback.
    let dev = try #require(
      CloudDeviceApprovalLink.parse(URL(string: "http://127.0.0.1:41234/device?user_code=ABCDEFGH")!))
    #expect(dev.serverURL == URL(string: "http://127.0.0.1:41234")!)
  }

  @Test("Rejects other pages, insecure remote origins, and missing or implausible codes")
  func rejectsOtherLinks() {
    let rejected = [
      "http://cloud.codevisor.dev/device?user_code=ABCD-EFGH",
      "codevisor://device?user_code=ABCD-EFGH",
      "https://cloud.codevisor.dev/login?user_code=ABCD-EFGH",
      "https://cloud.codevisor.dev/device/extra?user_code=ABCD-EFGH",
      "https://cloud.codevisor.dev/device",
      "https://cloud.codevisor.dev/device?user_code=",
      "https://cloud.codevisor.dev/device?user_code=----",
      "https://cloud.codevisor.dev/device?code=ABCD-EFGH",
      "https://cloud.codevisor.dev/device?user_code=ABCD%20EFGH",
      "https://cloud.codevisor.dev/device?user_code=\(String(repeating: "A", count: 33))",
      "https://user:pass@cloud.codevisor.dev/device?user_code=ABCD-EFGH",
    ]
    for raw in rejected {
      #expect(CloudDeviceApprovalLink.parse(URL(string: raw)!) == nil, "expected nil for \(raw)")
    }
  }

  @Test("Origins compare scheme, host, and effective port but not path")
  func sameOrigin() {
    let cloud = URL(string: "https://cloud.codevisor.dev")!
    #expect(CloudDeviceApprovalLink.sameOrigin(cloud, URL(string: "https://CLOUD.codevisor.dev:443/base/")!))
    #expect(!CloudDeviceApprovalLink.sameOrigin(cloud, URL(string: "https://cloud.codevisor.dev:8443")!))
    #expect(!CloudDeviceApprovalLink.sameOrigin(cloud, URL(string: "http://cloud.codevisor.dev")!))
    #expect(!CloudDeviceApprovalLink.sameOrigin(cloud, URL(string: "https://cloud.codevisor.dev.evil.example")!))
  }
}
