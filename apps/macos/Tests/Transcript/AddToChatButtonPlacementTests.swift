import CoreGraphics
import Testing
@testable import TranscriptSurface

@Suite("Add to Chat button placement")
struct AddToChatButtonPlacementTests {
  private let firstLine = CGRect(x: 100, y: 200, width: 400, height: 20)
  private let lastLine = CGRect(x: 40, y: 220, width: 180, height: 20)
  private let pane = CGRect(x: 0, y: 0, width: 600, height: 800)
  private let button = CGSize(width: 120, height: 30)

  @Test func centersAboveThePointerOnTheLineWhereTheDragEnded() throws {
    let placement = try #require(
      AddToChatButtonPlacement(lineRects: [firstLine, lastLine], pointer: CGPoint(x: 210, y: 231), bounds: pane)
    )

    #expect(placement.origin(for: button) == CGPoint(x: 150, y: 188))
  }

  @Test func picksTheSelectedLineNearestToAPointerOutsideTheText() throws {
    let placement = try #require(
      AddToChatButtonPlacement(lineRects: [firstLine, lastLine], pointer: CGPoint(x: 300, y: 600), bounds: pane)
    )

    #expect(placement.origin(for: button) == CGPoint(x: 240, y: 188))
  }

  @Test func fallsBackToTheSelectionEndWithoutAPointer() throws {
    let placement = try #require(
      AddToChatButtonPlacement(lineRects: [firstLine, lastLine], pointer: nil, bounds: pane)
    )

    #expect(placement.origin(for: button) == CGPoint(x: 160, y: 188))
  }

  @Test func staysInsideThePaneAndFlipsBelowWhenThereIsNoRoomAbove() throws {
    let topLine = CGRect(x: 0, y: 10, width: 600, height: 20)
    let placement = try #require(
      AddToChatButtonPlacement(lineRects: [topLine], pointer: CGPoint(x: 595, y: 20), bounds: pane)
    )

    #expect(placement.origin(for: button) == CGPoint(x: 480, y: 32))
  }

  @Test func showsNothingWithoutSelectedLines() {
    #expect(AddToChatButtonPlacement(lineRects: [], pointer: CGPoint(x: 10, y: 10), bounds: pane) == nil)
  }
}
