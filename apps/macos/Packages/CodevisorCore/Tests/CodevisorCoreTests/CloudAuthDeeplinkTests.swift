import Foundation
import Testing
@testable import CodevisorCore

@Suite("CloudAuthDeeplink")
struct CloudAuthDeeplinkTests {
    @Test("Parses production and dev scheme links")
    func parsesBothSchemes() {
        let production = URL(string: "codevisor://cloud-auth?ott=abc123")!
        #expect(CloudAuthDeeplink.parse(production) == CloudAuthDeeplink(ott: "abc123"))

        let dev = URL(string: "codevisor-dev://cloud-auth?ott=xyz-789")!
        #expect(CloudAuthDeeplink.parse(dev) == CloudAuthDeeplink(ott: "xyz-789"))
    }

    @Test("Percent-encoded tokens are decoded")
    func decodesEncodedToken() {
        let url = URL(string: "codevisor://cloud-auth?ott=a%2Bb%3Dc")!
        #expect(CloudAuthDeeplink.parse(url)?.ott == "a+b=c")
    }

    @Test("Rejects foreign schemes, other hosts, and a missing token")
    func rejectsInvalidLinks() {
        let rejected = [
            "https://cloud-auth?ott=abc",
            "codevisor://add-machine?ott=abc",
            "codevisor://cloud-auth",
            "codevisor://cloud-auth?ott=",
            "codevisor://cloud-auth?ott=%20",
            "codevisor://cloud-auth?token=abc"
        ]
        for raw in rejected {
            #expect(CloudAuthDeeplink.parse(URL(string: raw)!) == nil, "expected nil for \(raw)")
        }
    }
}
