import Foundation
@preconcurrency import RiveRuntime

@MainActor
final class BotMascotRig {
  private static let artboardName = "Bot Mascot"
  private static let stateMachineName = "Bot Mascot"

  let rive: Rive
  private let instance: ViewModelInstance
  private var motion: BotMascotMotion?
  private var gaze: BotMascotGaze?

  private init(rive: Rive, instance: ViewModelInstance) {
    self.rive = rive
    self.instance = instance
  }

  static func make(file: File, values: BotMascotRiveValues) async throws -> BotMascotRig {
    let artboard = try await file.createArtboard(artboardName)
    let instance = try await file.createViewModelInstance(.viewModelDefault(from: .artboardDefault(artboard)))
    values.apply(to: instance)
    let machine = try await artboard.createStateMachine(stateMachineName, binding: instance)
    let rive = try await Rive(file: file, artboard: artboard, stateMachine: machine)
    return BotMascotRig(rive: rive, instance: instance)
  }

  func dress(_ values: BotMascotRiveValues) {
    values.apply(to: instance)
  }

  func show(_ motion: BotMascotMotion) {
    guard motion != self.motion else { return }

    self.motion = motion
    instance.setValue(of: EnumProperty(path: "mode"), to: motion.riveMode)
  }

  func look(_ gaze: BotMascotGaze) {
    guard gaze != self.gaze else { return }

    self.gaze = gaze
    instance.setValue(of: NumberProperty(path: "gazeX"), to: gaze.x)
    instance.setValue(of: NumberProperty(path: "gazeY"), to: gaze.y)
    instance.setValue(of: NumberProperty(path: "gazeWeight"), to: gaze.weight)
  }

  func advance(by seconds: Double) {
    rive.stateMachine.advance(by: seconds)
  }

  func settle(for seconds: Double, step: Double) {
    for _ in 0..<Int((seconds / step).rounded()) {
      advance(by: step)
    }
  }

  func configuration(drawableSize: CGSize) -> RiveUIRendererConfiguration {
    RiveUIRendererConfiguration(rive: rive, drawableSize: drawableSize)
  }
}
