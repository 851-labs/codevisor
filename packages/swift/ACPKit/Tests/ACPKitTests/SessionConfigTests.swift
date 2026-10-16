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
    let option = try JSONDecoder().decode(SessionConfigOption.self, from: Data(json.utf8))
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
    let option = try JSONDecoder().decode(SessionConfigOption.self, from: Data(json.utf8))
    #expect(option.options.map(\.value) == ["a", "b"])
  }

  @Test("currentName falls back to the raw value when unknown")
  func unknownCurrent() {
    let option = SessionConfigOption(id: "x", name: "X", currentValue: "zzz", options: [])
    #expect(option.currentName == "zzz")
  }

  @Test("Encodes and decodes a config option with literal wire fields")
  func roundTrip() throws {
    let option = SessionConfigOption(
      id: "reasoning", name: "Reasoning", description: "effort", category: "thought_level",
      currentValue: "high",
      options: [
        SessionConfigSelectOption(value: "low", name: "low"),
        SessionConfigSelectOption(value: "high", name: "high"),
      ]
    )
    let data = try JSONEncoder().encode(option)
    let literal = Data(
      #"{"id":"reasoning","name":"Reasoning","description":"effort","category":"thought_level","currentValue":"high","options":[{"value":"low","name":"low"},{"value":"high","name":"high"}]}"#
        .utf8)
    let actual = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    let expected = try #require(try JSONSerialization.jsonObject(with: literal) as? NSDictionary)
    #expect(actual == expected)
    #expect(try JSONDecoder().decode(SessionConfigOption.self, from: literal) == option)
  }

  @Test("config_option_update session update round-trips")
  func configUpdate() throws {
    let update = SessionUpdate.configOptionUpdate([
      SessionConfigOption(
        id: "model", name: "Model", currentValue: "a",
        options: [SessionConfigSelectOption(value: "a", name: "A")])
    ])
    let data = try JSONEncoder().encode(update)
    let literal = Data(
      #"{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","name":"Model","currentValue":"a","options":[{"value":"a","name":"A"}]}]}"#
        .utf8)
    let actual = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    let expected = try #require(try JSONSerialization.jsonObject(with: literal) as? NSDictionary)
    #expect(actual == expected)
    #expect(try JSONDecoder().decode(SessionUpdate.self, from: literal) == update)
  }

  @Test("usage_update session update decodes cost + context tokens")
  func usageUpdate() throws {
    let json =
      #"{"sessionUpdate":"usage_update","used":12345,"size":200000,"inputTokens":9000,"cachedInputTokens":2000,"outputTokens":1345,"totalTokens":12345,"cost":{"amount":0.0123,"currency":"USD","kind":"reported"}}"#
    let update = try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))
    guard case let .usageUpdate(usage) = update else {
      Issue.record("expected usageUpdate, got \(update)")
      return
    }
    #expect(usage.used == 12345)
    #expect(usage.size == 200_000)
    #expect(usage.inputTokens == 9_000)
    #expect(usage.cachedInputTokens == 2_000)
    #expect(usage.outputTokens == 1_345)
    #expect(usage.totalTokens == 12_345)
    #expect(usage.cost == SessionCost(amount: 0.0123, currency: "USD", kind: .reported))
    let data = try JSONEncoder().encode(update)
    let actual = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    let expected = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    #expect(actual == expected)
  }

  @Test("usage_update tolerates a missing cost")
  func usageUpdateNoCost() throws {
    let json = #"{"sessionUpdate":"usage_update","used":10}"#
    let update = try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))
    #expect(update == .usageUpdate(SessionUsage(used: 10)))
  }

  @Test("Category constants match the spec")
  func categories() {
    #expect(SessionConfigOption.Category.model == "model")
    #expect(SessionConfigOption.Category.thoughtLevel == "thought_level")
    #expect(SessionConfigOption.Category.mode == "mode")
  }
}
