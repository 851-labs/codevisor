import CodevisorCore
@preconcurrency import RiveRuntime
import SwiftUI

struct BotMascotRiveView: View {
  private static let artboardSide: CGFloat = 500
  private static let figureBox = CGRect(x: 51, y: 30, width: 398, height: 398)
  private static let frameInterval = Duration.milliseconds(16)

  let mascot: ServerBotMascot
  let serverId: String
  let mode: BotMascotRiveMode

  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @State private var scene: BotMascotRiveScene?
  @State private var pointer = BotMascotPointer()

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / Self.figureBox.width
      ZStack(alignment: .topLeading) {
        if let scene {
          RiveUIViewRepresentable(rive: scene.rive)
            .frame(width: Self.artboardSide * scale, height: Self.artboardSide * scale)
            .offset(x: -Self.figureBox.minX * scale, y: -Self.figureBox.minY * scale)
        } else {
          BotMascotImage(mascot: mascot, serverId: serverId, kind: .figure)
        }
        BotMascotPointerProbe(pointer: pointer)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .clipped()
    }
    .accessibilityHidden(true)
    .task(id: mascot) { await load() }
    .task(id: Playing(scene: scene.map(ObjectIdentifier.init), mode: mode)) { await play() }
  }

  private func load() async {
    guard let environment else { return }

    let client = environment.machines.client(for: serverId)
    let files = BotMascotRiveFiles.shared
    do {
      let file = try await files.file(serverId: serverId, client: client, mascot: mascot)
      let values = try await files.values(for: mascot, client: client)
      scene = try await BotMascotRiveScene.make(file: file, values: values)
    } catch {
      scene = nil
    }
  }

  private func play() async {
    guard let scene else { return }

    scene.show(mode)
    guard mode == .idle else { return scene.look(.none) }

    await followPointer(in: scene)
  }

  private func followPointer(in scene: BotMascotRiveScene) async {
    var follower = BotMascotGazeFollower()
    let clock = ContinuousClock()
    var last = clock.now
    while !Task.isCancelled {
      let now = clock.now
      let seconds = Double((now - last) / .seconds(1))
      last = now
      scene.look(follower.step(toward: pointer.location().map(artboardPoint), seconds: seconds))
      do {
        try await Task.sleep(for: Self.frameInterval)
      } catch {
        return
      }
    }
  }

  private func artboardPoint(_ point: CGPoint) -> CGPoint {
    guard let view = pointer.viewSide, view > 0 else { return point }

    let unit = Self.figureBox.width / view
    return CGPoint(x: Self.figureBox.minX + point.x * unit, y: Self.figureBox.minY + point.y * unit)
  }
}

private struct Playing: Equatable {
  let scene: ObjectIdentifier?
  let mode: BotMascotRiveMode
}
