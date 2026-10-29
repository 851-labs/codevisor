import CoreGraphics

@MainActor
enum DisplayOption {
  static let usage = "[--display <id>]"

  static func id(from options: BenchOptions, named name: String = "display") throws -> CGDirectDisplayID? {
    let id = try options.integer(name, default: 0, in: 0...Int(UInt32.max))
    return id == 0 ? nil : CGDirectDisplayID(id)
  }
}
