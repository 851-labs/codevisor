import Foundation
import Testing
@testable import CodevisorCloud

@Suite("CloudDeflate")
struct CloudDeflateTests {
    @Test("Round-trips deflate/inflate")
    func roundTrip() throws {
        for payload in [Data(), Data("x".utf8), Data(String(repeating: "codevisor ", count: 500).utf8)] {
            #expect(try CloudDeflate.inflate(CloudDeflate.deflate(payload)) == payload)
        }
    }

    @Test("Inflates a raw-DEFLATE vector produced by node's deflateRawSync")
    func nodeVector() throws {
        // Generated with node: deflateRawSync(Buffer.from(plain)).toString("base64")
        let plain =
            "compression vector: the quick brown fox jumps over the lazy dog, repeated. the quick brown fox jumps over the lazy dog."
        let deflatedBase64 =
            "lcvZDYAgEAXAVl4BxgLsBmFVVHi4HB7Vm9iB35OxDEklZ8+IJrZQB5RFcFRvN4zKM2LihbWGlMEm+vFunhuOcweVJKaI6/+0/gU="
        let deflated = try #require(Data(base64Encoded: deflatedBase64))
        #expect(try CloudDeflate.inflate(deflated) == Data(plain.utf8))
    }

    @Test("Rejects corrupt input")
    func corrupt() {
        #expect(throws: CloudDeflateError.corruptInput) {
            _ = try CloudDeflate.inflate(Data([0xFF, 0x00, 0xAB, 0xCD, 0xEF]))
        }
    }
}
