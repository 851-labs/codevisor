import Foundation
import Testing
@testable import CodevisorCore

@Suite("MachineDeeplink")
struct MachineDeeplinkTests {
    @Test("Parses a full add-machine link")
    func parsesFullLink() {
        let url = URL(
            string:
            "codevisor://add-machine?host=box.tail.net&port=49361&token=hm_abc&name=Build%20Box"
        )!
        let deeplink = MachineDeeplink.parse(url)
        #expect(deeplink == MachineDeeplink(
            host: "box.tail.net",
            port: 49_361,
            token: "hm_abc",
            name: "Build Box"
        ))
        #expect(deeplink?.hostWithPort == "box.tail.net:49361")
        #expect(deeplink?.displayName == "Build Box")
    }

    @Test("Accepts the dev scheme and minimal parameters")
    func parsesDevSchemeAndMinimalLink() {
        let url = URL(string: "codevisor-dev://add-machine?host=10.0.0.5&token=hm_x")!
        let deeplink = MachineDeeplink.parse(url)
        #expect(deeplink == MachineDeeplink(host: "10.0.0.5", token: "hm_x"))
        #expect(deeplink?.hostWithPort == "10.0.0.5")
        #expect(deeplink?.displayName == "10.0.0.5")
    }

    @Test("Rejects foreign schemes, other actions, and missing pairing data")
    func rejectsInvalidLinks() {
        let rejected = [
            "https://add-machine?host=h&token=t",
            "codevisor://open-session?id=1",
            "codevisor://add-machine?host=box.tail.net",
            "codevisor://add-machine?token=hm_x",
            "codevisor://add-machine?host=%20&token=hm_x"
        ]
        for raw in rejected {
            #expect(MachineDeeplink.parse(URL(string: raw)!) == nil, "expected nil for \(raw)")
        }
    }

    @Test("Ignores out-of-range or malformed ports")
    func ignoresBadPorts() {
        let malformed = URL(string: "codevisor://add-machine?host=h&token=t&port=eleven")!
        #expect(MachineDeeplink.parse(malformed)?.port == nil)
        let outOfRange = URL(string: "codevisor://add-machine?host=h&token=t&port=70000")!
        #expect(MachineDeeplink.parse(outOfRange)?.port == nil)
    }
}
