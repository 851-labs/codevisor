import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingV2

struct EncoderReleaseCommand: BenchCommand {
  static let name = "encoder-release"
  static let summary =
    "Open and stop the VCP tile encoder in one process and count the VideoToolbox HEVC sessions another process gets"
  static let usage = "[--rounds 3] [--width 3840] [--height 2160] [--vt-limit 48] [--settle 2] | --count-vt <limit>"

  let presentsWindows = false
  private let rounds: Int
  private let width: Int
  private let height: Int
  private let limit: Int
  private let settleSeconds: Int
  private let countsOnly: Bool

  init(options: BenchOptions) throws {
    rounds = try options.integer("rounds", default: 3, in: 1...50)
    width = try options.integer("width", default: 3840, in: 64...7680)
    height = try options.integer("height", default: 2160, in: 64...4320)
    settleSeconds = try options.integer("settle", default: 2, in: 0...60)
    let countLimit = try options.string("count-vt")
    countsOnly = countLimit != nil
    limit = try countLimit.map { text in
      guard let value = Int(text), (1...256).contains(value) else {
        throw BenchUsageError(message: "--count-vt takes a session limit from 1 to 256")
      }

      return value
    } ?? options.integer("vt-limit", default: 48, in: 1...256)
  }

  func run() async throws {
    guard !countsOnly else { return try BenchOutput.print(EncoderReleaseVTCount.measure(limit: limit)) }

    var steps = [EncoderReleaseStep(label: "before", count: try otherProcess())]
    for round in 1...rounds {
      let encoder = try ScreenSharingVCPTileEncoder(
        configuration: try ScreenSharingV2Profile.captureConfiguration(width: width, height: height),
        metrics: ScreenSharingMetrics())
      let encoded = try await EncoderReleaseFrame.encode(with: encoder, width: width, height: height)
      if round == 1 { steps.append(EncoderReleaseStep(label: "open, \(encoded) tiles encoded", count: try otherProcess())) }
      encoder.stop()
      try await Task.sleep(for: .seconds(settleSeconds))
      steps.append(EncoderReleaseStep(label: "after round \(round)", count: try otherProcess()))
    }
    try BenchOutput.print(EncoderReleaseReport(steps: steps))
  }

  private func otherProcess() throws -> EncoderReleaseVTCount {
    guard let executable = Bundle.main.executableURL else {
      throw BenchUsageError(message: "encoder-release can't find its own executable")
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = [Self.name, "--count-vt", "\(limit)"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(EncoderReleaseVTCount.self, from: data)
  }
}
