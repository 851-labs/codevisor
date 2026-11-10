import Foundation
import SwiftUI
import Testing

@testable import CodevisorUI

struct FileTreeSelectionTests {
  private let rows = ["a", "b", "c", "d", "e"]

  @Test func commandClickTogglesWithoutDroppingTheRest() {
    var selection = FileTreeSelection()
    selection.select("b")
    selection.toggle("d")
    #expect(selection.ordered(in: rows) == ["b", "d"])

    selection.toggle("b")
    #expect(selection.ordered(in: rows) == ["d"])
  }

  @Test func shiftClickSelectsTheRangeFromTheAnchorInEitherDirection() {
    var selection = FileTreeSelection()
    selection.select("c")
    selection.extend(to: "e", in: rows)
    #expect(selection.ordered(in: rows) == ["c", "d", "e"])

    selection.extend(to: "a", in: rows)
    #expect(selection.ordered(in: rows) == ["a", "b", "c"])
  }

  @Test func shiftArrowsGrowAndShrinkAroundTheAnchor() {
    var selection = FileTreeSelection()
    selection.select("b")
    selection.move(by: 1, in: rows, extending: true)
    selection.move(by: 1, in: rows, extending: true)
    #expect(selection.ordered(in: rows) == ["b", "c", "d"])

    selection.move(by: -1, in: rows, extending: true)
    #expect(selection.ordered(in: rows) == ["b", "c"])
    #expect(selection.cursor == "c")
  }

  @Test func arrowsStartAtTheEdgesAndStopThere() {
    var selection = FileTreeSelection()
    #expect(selection.move(by: 1, in: rows, extending: false) == "a")
    #expect(selection.move(by: -1, in: rows, extending: false) == nil)
    #expect(selection.single == "a")

    var fromBottom = FileTreeSelection()
    #expect(fromBottom.move(by: -1, in: rows, extending: false) == "e")
  }

  @Test func plainArrowCollapsesAMultipleSelection() {
    var selection = FileTreeSelection()
    selection.selectAll(rows)
    selection.move(by: -1, in: rows, extending: false)
    #expect(selection.single == "d")
  }

  @Test func rowsThatScrollAwayOrCollapseLeaveTheSelection() {
    var selection = FileTreeSelection()
    selection.select("b")
    selection.extend(to: "d", in: rows)
    selection.retain(["a", "b", "e"])
    #expect(selection.ordered(in: rows) == ["b"])
    #expect(selection.cursor == nil)
  }

  @Test func typingJumpsToTheFirstMatchingNameUntilAPause() {
    var buffer = TypeSelectBuffer()
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let names = [(id: "1", name: "assets"), (id: "2", name: "index.html"), (id: "3", name: "Info.plist")]

    #expect(TypeSelectBuffer.match(buffer.type("i", at: start), in: names) == "2")
    #expect(TypeSelectBuffer.match(buffer.type("N", at: start.addingTimeInterval(0.5)), in: names) == "2")
    #expect(TypeSelectBuffer.match(buffer.type("f", at: start.addingTimeInterval(0.9)), in: names) == "3")
    #expect(buffer.type("a", at: start.addingTimeInterval(2)) == "a")
  }

  @Test func finderShortcutsMapToTreeCommands() {
    let command = { (key: KeyEquivalent, modifiers: EventModifiers, characters: String) in
      FileTreeKeyCommand.command(key: key, modifiers: modifiers, characters: characters)
    }
    #expect(command(.downArrow, [.shift], "") == .move(by: 1, extending: true))
    #expect(command(.downArrow, [.command], "") == .open)
    #expect(command(.upArrow, [.command], "") == .selectParent)
    #expect(command(.return, [], "\r") == .rename)
    #expect(command(.delete, [.command], "\u{7f}") == .delete)
    #expect(command(.delete, [], "\u{7f}") == nil)
    #expect(command(KeyEquivalent("\u{7F}"), [.command], "\u{7f}") == .delete)
    #expect(command("a", [.command], "a") == .selectAll)
    #expect(command("c", [.command], "c") == .copy)
    #expect(command("v", [.command], "v") == nil)
    #expect(command("r", [.shift], "R") == .typeSelect("R"))
    #expect(command("r", [.control], "\u{12}") == nil)
  }
}
