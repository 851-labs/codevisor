import ScreenSharing

extension RFBCursorShape {
  public static let referenceArrow: RFBCursorShape = {
    let art = [
      "X..........",
      "XX.........",
      "XOX........",
      "XOOX.......",
      "XOOOX......",
      "XOOOOX.....",
      "XOOOOOX....",
      "XOOOOOOX...",
      "XOOOOOOOX..",
      "XOOOOOOOOX.",
      "XOOOOOXXXXX",
      "XOOXOOX....",
      "XOX.XOOX...",
      "XX..XOOX...",
      "X....XOOX..",
      ".....XXXX..",
    ]
    let pixels = art.flatMap { row in
      row.flatMap { cell -> [UInt8] in
        switch cell {
        case "X": [0, 0, 0, 255]
        case "O": [255, 255, 255, 255]
        default: [0, 0, 0, 0]
        }
      }
    }
    return RFBCursorShape(width: 11, height: 16, hotspotX: 0, hotspotY: 0, pixels: pixels)
  }()
}
