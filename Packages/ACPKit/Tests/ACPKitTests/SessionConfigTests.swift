import Foundation
import Testing
@testable import ACPKit

@Suite("Session config options")
struct SessionConfigTests {
    @Test("Decodes a real model config option")
    func decodesModelOption() throws {
        let json = """
        {"id":"model","name":"Model","description":"Model Codex uses","category":"model","type":"select",
         "currentValue":"gpt-5.5",
         "options":[{"value":"gpt-5.5","name":"GPT-5.5","description":"Frontier"},
                    {"value":"gpt-5.4","name":"GPT-5.4"}]}
        """
        let option = try ACPJSON.decoder.decode(SessionConfigOption.self, from: Data(json.utf8))
        #expect(option.id == "model")
        #expect(option.category == "model")
        #expect(option.currentValue == "gpt-5.5")
        #expect(option.options.count == 2)
        #expect(option.currentName == "GPT-5.5")
    }

    @Test("Flattens grouped options")
    func grouped() throws {
        let json = """
        {"id":"model","name":"Model","currentValue":"a",
         "options":[{"group":"g1","name":"Group 1","options":[{"value":"a","name":"A"},{"value":"b","name":"B"}]}]}
        """
        let option = try ACPJSON.decoder.decode(SessionConfigOption.self, from: Data(json.utf8))
        #expect(option.options.map(\.value) == ["a", "b"])
    }

    @Test("currentName falls back to the raw value when unknown")
    func unknownCurrent() {
        let option = SessionConfigOption(id: "x", name: "X", currentValue: "zzz", options: [])
        #expect(option.currentName == "zzz")
    }

    @Test("Round-trips a config option and the set request/response")
    func roundTrip() throws {
        let option = SessionConfigOption(
            id: "reasoning", name: "Reasoning", description: "effort", category: "thought_level",
            currentValue: "high",
            options: [SessionConfigSelectOption(value: "low", name: "low"), SessionConfigSelectOption(value: "high", name: "high")]
        )
        let data = try ACPJSON.encoder.encode(option)
        #expect(try ACPJSON.decoder.decode(SessionConfigOption.self, from: data) == option)

        let request = SetSessionConfigOptionRequest(sessionId: "s", configId: "model", value: "gpt-5.4")
        let requestData = try ACPJSON.encoder.encode(request)
        #expect(try ACPJSON.decoder.decode(SetSessionConfigOptionRequest.self, from: requestData) == request)

        let response = SetSessionConfigOptionResponse(configOptions: [option])
        let responseData = try ACPJSON.encoder.encode(response)
        #expect(try ACPJSON.decoder.decode(SetSessionConfigOptionResponse.self, from: responseData) == response)
    }

    @Test("config_option_update session update round-trips")
    func configUpdate() throws {
        let update = SessionUpdate.configOptionUpdate([
            SessionConfigOption(id: "model", name: "Model", currentValue: "a",
                                options: [SessionConfigSelectOption(value: "a", name: "A")])
        ])
        let data = try ACPJSON.encoder.encode(update)
        #expect(try ACPJSON.decoder.decode(SessionUpdate.self, from: data) == update)
    }

    @Test("NewSessionResponse carries config options")
    func newSessionConfig() throws {
        let response = NewSessionResponse(
            sessionId: "s",
            configOptions: [SessionConfigOption(id: "model", name: "Model", currentValue: "a", options: [])]
        )
        let data = try ACPJSON.encoder.encode(response)
        #expect(try ACPJSON.decoder.decode(NewSessionResponse.self, from: data) == response)
    }

    @Test("Category constants match the spec")
    func categories() {
        #expect(SessionConfigOption.Category.model == "model")
        #expect(SessionConfigOption.Category.thoughtLevel == "thought_level")
        #expect(SessionConfigOption.Category.mode == "mode")
    }
}
