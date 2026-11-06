import CodevisorCore
import SwiftUI

struct BotMascotRiveView: View {
  let key: BotMascotStageKey
  let mascot: ServerBotMascot

  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @State private var pointer = BotMascotPointer()

  private var stage: BotMascotStage { BotMascotStages.shared.stage(for: key) }

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / BotMascotFraming.figureBox.width
      let side = BotMascotFraming.artboardSide * scale
      ZStack(alignment: .topLeading) {
        if !stage.isReady {
          BotMascotImage(mascot: mascot, serverId: key.serverId, kind: .figure)
        }
        BotMascotRiveCanvas(stage: stage, pointer: pointer)
          .frame(width: side, height: side)
          .offset(x: -BotMascotFraming.figureBox.minX * scale, y: -BotMascotFraming.figureBox.minY * scale)
          .opacity(stage.isReady ? 1 : 0)
        BotMascotPointerProbe(pointer: pointer)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .clipped()
    }
    .accessibilityHidden(true)
    .task(id: mascot) { dress() }
  }

  private func dress() {
    guard let environment else { return }

    stage.dress(as: mascot, retrying: MachineRetry(machineId: key.serverId, machines: environment.machines))
  }
}
