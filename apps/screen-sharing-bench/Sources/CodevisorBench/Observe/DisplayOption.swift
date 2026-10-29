import CoreGraphics

@MainActor
enum DisplayOption {
  static let usage = "[--display <id>]"

  static func id(from options: BenchOptions) throws -> CGDirectDisplayID? {
    let id = try options.integer("display", default: 0, in: 0...Int(UInt32.max))
    return id == 0 ? nil : CGDirectDisplayID(id)
  }
}
