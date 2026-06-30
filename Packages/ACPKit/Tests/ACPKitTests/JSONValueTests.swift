import Foundation
import Testing
@testable import ACPKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Round-trips every JSON kind")
    func roundTrip() throws {
        let value: JSONValue = .object([
            "null": .null,
            "bool": .bool(true),
            "number": .number(3.5),
            "string": .string("hi"),
            "array": .array([1, 2, 3]),
            "nested": .object(["a": "b"])
        ])
        let data = try ACPJSON.encoder.encode(value)
        let decoded = try ACPJSON.decoder.decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Literal conformances build expected values")
    func literals() {
        let value: JSONValue = ["a": 1, "b": "two", "c": true, "d": nil, "e": 1.5]
        #expect(value["a"] == .number(1))
        #expect(value["b"] == .string("two"))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .null)
        #expect(value["e"] == .number(1.5))
        let array: JSONValue = [1, 2]
        #expect(array.arrayValue?.count == 2)
    }

    @Test("Typed accessors return values or nil")
    func accessors() {
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.number(7).intValue == 7)
        #expect(JSONValue.number(2.5).doubleValue == 2.5)
        #expect(JSONValue.bool(false).boolValue == false)
        #expect(JSONValue.object(["k": "v"]).objectValue?["k"] == .string("v"))
        // Wrong-type accessors return nil.
        #expect(JSONValue.null.stringValue == nil)
        #expect(JSONValue.string("x").intValue == nil)
        #expect(JSONValue.string("x").doubleValue == nil)
        #expect(JSONValue.string("x").boolValue == nil)
        #expect(JSONValue.string("x").arrayValue == nil)
        #expect(JSONValue.string("x").objectValue == nil)
        #expect(JSONValue.string("x")["key"] == nil)
    }

    @Test("Decoding an unsupported root throws")
    func unsupported() throws {
        // A bare top-level value that is valid still decodes; ensure invalid JSON throws.
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(JSONValue.self, from: Data("{".utf8))
        }
    }

    @Test("ACPJSON value/decode bridge round-trips Codable types")
    func bridge() throws {
        let original = PromptResponse(stopReason: .endTurn)
        let value = try ACPJSON.value(from: original)
        let back = try ACPJSON.decode(PromptResponse.self, from: value)
        #expect(back == original)
    }
}
