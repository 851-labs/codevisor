import CodevisorCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BotMascotStillDisk: Sendable {
  private let root: URL
  private let version: String

  init(root: URL, version: String) {
    self.root = root
    self.version = version
  }

  func image(_ still: BotMascotStill) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url(still) as CFURL, nil) else { return nil }

    let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    return CGImageSourceCreateImageAtIndex(source, 0, options)
  }

  func store(_ image: CGImage, as still: BotMascotStill) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try png(image).write(to: url(still), options: .atomic)
    } catch {
      Log.persistence.error("Failed to cache a mascot still: \(String(describing: error), privacy: .public)")
    }
  }

  func removeOtherVersions() {
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for folder in folders where folder.lastPathComponent != version {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  private var directory: URL { root.appendingPathComponent(version, isDirectory: true) }

  private func url(_ still: BotMascotStill) -> URL {
    directory.appendingPathComponent(still.fileName)
  }

  private func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
  }
}
