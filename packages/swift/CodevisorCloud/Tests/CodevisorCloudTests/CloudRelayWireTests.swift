import Foundation
import Testing
@testable import CodevisorCloud

@Suite("CloudRelayWire")
struct CloudRelayWireTests {
    @Test("Round-trips a coalesced batch of envelopes in order")
    func roundTrip() throws {
        let envelopes = [
            CloudRelayEnvelope(header: Data(#"{"machineId":"m","frame":1}"#.utf8), payload: Data([1, 2, 3])),
            CloudRelayEnvelope(header: Data(#"{"machineId":"m","frame":2}"#.utf8), payload: Data()),
            CloudRelayEnvelope(header: Data(#"{"x":3}"#.utf8), payload: Data(repeating: 7, count: 300)),
        ]
        let decoded = try CloudRelayWire.decode(CloudRelayWire.encode(envelopes))
        #expect(decoded.count == 3)
        for (original, roundTripped) in zip(envelopes, decoded) {
            #expect(roundTripped.header == original.header)
            #expect(roundTripped.payload == original.payload)
        }
    }

    @Test("Decodes payloads at the right offsets in a non-zero-based Data slice")
    func sliceSafety() throws {
        // Data slices keep their parent's indices; the decoder must not assume
        // a zero startIndex.
        let message = CloudRelayWire.encode([
            CloudRelayEnvelope(header: Data(#"{"a":1}"#.utf8), payload: Data([9]))
        ])
        let padded = Data([0xFF, 0xFF]) + message
        let slice = padded.dropFirst(2)
        let decoded = try CloudRelayWire.decode(Data(slice))
        #expect(decoded.count == 1)
        #expect(decoded[0].payload == Data([9]))
    }

    @Test("Rejects truncated and empty messages")
    func malformed() {
        #expect(throws: CloudRelayWireError.empty) {
            _ = try CloudRelayWire.decode(Data())
        }
        #expect(throws: CloudRelayWireError.truncated) {
            _ = try CloudRelayWire.decode(Data([0, 0]))
        }
        // Header length pointing past the end.
        #expect(throws: CloudRelayWireError.truncated) {
            _ = try CloudRelayWire.decode(Data([0, 0, 0, 99, 1]))
        }
        // Valid header, truncated payload.
        let good = CloudRelayWire.encode([
            CloudRelayEnvelope(header: Data(#"{"a":1}"#.utf8), payload: Data([1, 2, 3, 4]))
        ])
        #expect(throws: CloudRelayWireError.truncated) {
            _ = try CloudRelayWire.decode(good.dropLast(2))
        }
    }
}
