import CodevisorCore
import SwiftUI

struct BotMascotRiveView: View {
  let key: BotMascotStageKey
  let mascot: ServerBotMascot
  let pose: BotMascotMotion

  @State private var pointer = BotMascotPointer()
  @State private var isCanvasShowing = false

  private var stage: BotMascotStage { BotMascotStages.shared.stage(for: key) }

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / BotMascotFraming.figureBox.width
      let side = BotMascotFraming.artboardSide * scale
      ZStack(alignment: .topLeading) {
        if !isCanvasShowing {
          BotMascotImage(BotMascotStill(mascot, framing: .figure, pose: pose))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        BotMascotRiveCanvas(stage: stage, pointer: pointer) { isCanvasShowing = true }
          .frame(width: side, height: side)
          .offset(x: -BotMascotFraming.figureBox.minX * scale, y: -BotMascotFraming.figureBox.minY * scale)
          .opacity(stage.isReady ? 1 : 0)
        BotMascotPointerProbe(pointer: pointer)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .clipped()
    }
    .accessibilityHidden(true)
    .task(id: mascot) { stage.dress(as: mascot) }
  }
}
