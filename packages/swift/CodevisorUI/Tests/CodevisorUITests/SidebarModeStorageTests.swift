import Foundation
import Testing
@testable import CodevisorUI

struct SidebarModeStorageTests {
  @Test func botsModeReadsAndWritesTheStoredChatValue() throws {
    let stored = Data(#""chat""#.utf8)

    #expect(try JSONDecoder().decode(SidebarMode.self, from: stored) == .bots)
    #expect(try JSONEncoder().encode(SidebarMode.bots) == stored)
  }

  @Test func rememberedSelectionsKeepTheirStoredChatKey() throws {
    let stored = Data(#"{"chat":"bot a","code":"tab a"}"#.utf8)

    let selections = try JSONDecoder().decode(SidebarModeSelections<String>.self, from: stored)

    #expect(selections == SidebarModeSelections(bots: "bot a", code: "tab a"))

    let encoded = try JSONEncoder().encode(SidebarModeSelections(bots: "bot a"))
    #expect(String(decoding: encoded, as: UTF8.self) == #"{"chat":"bot a"}"#)
  }
}
