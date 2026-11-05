import CodevisorCore
import Foundation
@preconcurrency import RiveRuntime

@MainActor
final class BotMascotRiveScene {
  private static let artboardName = "Bot Mascot"
  private static let stateMachineName = "Bot Mascot"

  let rive: Rive
  private let instance: ViewModelInstance
  private var mode: BotMascotRiveMode?
  private var gaze: BotMascotGaze?

  private init(rive: Rive, instance: ViewModelInstance) {
    self.rive = rive
    self.instance = instance
  }

  static func make(file: File, values: BotMascotRiveValues) async throws -> BotMascotRiveScene {
    let artboard = try await file.createArtboard(artboardName)
    let instance = try await file.createViewModelInstance(.viewModelDefault(from: .artboardDefault(artboard)))
    values.apply(to: instance)
    let machine = try await artboard.createStateMachine(stateMachineName, binding: instance)
    let rive = try await Rive(file: file, artboard: artboard, stateMachine: machine)
    return BotMascotRiveScene(rive: rive, instance: instance)
  }

  func show(_ mode: BotMascotRiveMode) {
    guard mode != self.mode else { return }

    self.mode = mode
    instance.setValue(of: EnumProperty(path: "mode"), to: mode.rawValue)
  }

  func look(_ gaze: BotMascotGaze) {
    guard gaze != self.gaze else { return }

    self.gaze = gaze
    instance.setValue(of: NumberProperty(path: "gazeX"), to: gaze.x)
    instance.setValue(of: NumberProperty(path: "gazeY"), to: gaze.y)
    instance.setValue(of: NumberProperty(path: "gazeWeight"), to: gaze.weight)
  }
}

enum BotMascotRiveMode: String {
  case idle
  case working
  case calling
}
