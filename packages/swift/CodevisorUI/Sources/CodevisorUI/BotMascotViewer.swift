import CoreGraphics

@MainActor
struct BotMascotViewer {
  weak var view: BotMascotCanvasView?
  let pointer: BotMascotPointer

  var target: CGPoint? {
    guard let location = pointer.location(), let side = pointer.viewSide else { return nil }

    return BotMascotFraming.artboardPoint(location, inFigureOfSide: side)
  }
}
