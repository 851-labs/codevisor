import AVFoundation
import Foundation

public struct CustomSoundStore: Sendable {
  public enum ImportError: Error, LocalizedError, Equatable {
    case unreadableAudio
    case emptyAudio
    case tooLong(seconds: Double)
    case conversionFailed

    public var errorDescription: String? {
      switch self {
      case .unreadableAudio:
        "This file isn't an audio format Codevisor can read. Try a WAV, MP3, M4A, or AIFF file."
      case .emptyAudio:
        "This audio file has no sound in it."
      case .tooLong(let seconds):
        String(
          format: "This sound is %.1f seconds long. Notification sounds can be at most %.0f seconds.",
          seconds,
          CustomSoundStore.maxDuration
        )
      case .conversionFailed:
        "Codevisor couldn't convert this sound. Try a different file."
      }
    }
  }

  public static let maxDuration: TimeInterval = 5

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public init() {
    self.init(directory: Self.defaultDirectory())
  }

  public static func defaultDirectory() -> URL {
    CodevisorAppVariant.applicationSupportURL()
      .appendingPathComponent("sounds", isDirectory: true)
  }

  public func availableSounds() -> [URL] {
    let manager = FileManager.default
    guard
      let urls = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    return
      urls
      .filter { $0.pathExtension.lowercased() == "caf" }
      .map(\.standardizedFileURL)
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  @discardableResult
  public func importSound(from url: URL) throws -> URL {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    let source: AVAudioFile
    do {
      source = try AVAudioFile(forReading: url)
    } catch {
      throw ImportError.unreadableAudio
    }
    let format = source.processingFormat
    guard source.length > 0, format.sampleRate > 0 else { throw ImportError.emptyAudio }
    let duration = Double(source.length) / format.sampleRate
    guard duration <= Self.maxDuration else { throw ImportError.tooLong(seconds: duration) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = availableDestination(for: url.deletingPathExtension().lastPathComponent)
    do {
      try convert(source, to: destination, format: format)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw (error as? ImportError) ?? ImportError.conversionFailed
    }
    return destination.standardizedFileURL
  }

  public func deleteSound(at url: URL) throws {
    let manager = FileManager.default
    try manager.removeItem(at: url)
    if let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first {
      let prepared =
        library
        .appendingPathComponent("Sounds", isDirectory: true)
        .appendingPathComponent(Self.preparedNotificationSoundName(for: url))
      try? manager.removeItem(at: prepared)
    }
  }

  public static func preparedNotificationSoundName(for source: URL) -> String {
    let safeBase = source.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    return "Codevisor-\(safeBase).\(source.pathExtension.lowercased())"
  }

  private func convert(_ source: AVAudioFile, to destination: URL, format: AVAudioFormat) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: format.channelCount,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = try AVAudioFile(
      forWriting: destination,
      settings: settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
      throw ImportError.conversionFailed
    }
    while source.framePosition < source.length {
      try source.read(into: buffer)
      guard buffer.frameLength > 0 else { break }
      try output.write(from: buffer)
    }
  }

  private func availableDestination(for baseName: String) -> URL {
    let manager = FileManager.default
    let base = baseName.isEmpty ? "Sound" : baseName
    var candidate = directory.appendingPathComponent("\(base).caf")
    var counter = 2
    while manager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(base) \(counter).caf")
      counter += 1
    }
    return candidate
  }
}
