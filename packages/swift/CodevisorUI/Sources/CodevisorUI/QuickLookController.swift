import CodevisorCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

public enum QuickLookItem: Equatable, Sendable {
  case local(fileURL: URL, name: String, mimeType: String)
  case remote(source: PreviewFile.Source, name: String, mimeType: String)

  public init(_ file: PreviewFile) {
    self = .remote(source: file.source, name: file.name, mimeType: file.mimeType)
  }

  public var name: String {
    switch self {
    case let .local(_, name, _): return name
    case let .remote(_, name, _): return name
    }
  }

  public var mimeType: String {
    switch self {
    case let .local(_, _, mimeType): return mimeType
    case let .remote(_, _, mimeType): return mimeType
    }
  }
}

extension EnvironmentValues {
  @Entry public var quickLook: QuickLookController? = nil
}

@MainActor
@Observable
public final class QuickLookController {
  public private(set) var previewURL: URL?
  public private(set) var loadingItem: QuickLookItem?
  @ObservationIgnored public var onFailure: (@MainActor (_ name: String, _ error: Error) -> Void)?
  private var temporaryDirectories: [URL] = []
  private var presentationTask: Task<Void, Never>?
  private var presentationID = UUID()

  public init() {}

  public func isLoading(_ item: QuickLookItem) -> Bool {
    loadingItem == item
  }

  @discardableResult
  public func present(_ item: QuickLookItem, attachmentStore: AttachmentImageStore?) -> Task<Void, Never> {
    presentationTask?.cancel()
    presentationID = UUID()
    let presentationID = presentationID
    loadingItem = item

    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if presentationID == self.presentationID { self.loadingItem = nil }
      }
      let itemName = item.name
      let itemMimeType = item.mimeType
      do {
        let contents: Contents
        switch item {
        case let .local(fileURL, _, _):
          contents = .file(fileURL)
        case let .remote(source, _, _):
          guard let attachmentStore else {
            throw QuickLookError.attachmentUnavailable
          }
          contents = .data(try await attachmentStore.data(for: source))
        }

        try Task.checkCancellation()
        guard presentationID == self.presentationID else { return }

        let materialized = try await Task.detached(priority: .userInitiated) {
          try Self.materialize(
            contents,
            name: itemName,
            mimeType: itemMimeType
          )
        }.value
        guard presentationID == self.presentationID else {
          try? FileManager.default.removeItem(at: materialized.directory)
          return
        }
        self.temporaryDirectories.append(materialized.directory)
        self.previewURL = materialized.file
      } catch is CancellationError {
      } catch {
        guard presentationID == self.presentationID else { return }
        self.showFailure(for: itemName, error: error)
      }
    }
    presentationTask = task
    return task
  }

  public func updatePreviewURL(_ url: URL?) {
    guard previewURL != url else { return }
    previewURL = url
    guard url == nil else { return }

    presentationTask?.cancel()
    presentationTask = nil
    presentationID = UUID()
    loadingItem = nil
    scheduleTemporaryDirectoryCleanup()
  }

  public func dismiss() {
    updatePreviewURL(nil)
  }

  private func scheduleTemporaryDirectoryCleanup() {
    let directories = temporaryDirectories
    temporaryDirectories.removeAll()
    Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      for directory in directories {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }

  private func showFailure(for name: String, error: Error) {
    Log.attachments.error(
      "Quick Look preparation failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)"
    )
    onFailure?(name, error)
  }

  private enum Contents: Sendable {
    case data(Data)
    case file(URL)
  }

  nonisolated private static func materialize(
    _ contents: Contents,
    name: String,
    mimeType: String
  ) throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Codevisor-QuickLook", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    do {
      let file = directory.appendingPathComponent(
        safeFilename(name: name, mimeType: mimeType),
        isDirectory: false
      )
      switch contents {
      case let .data(data):
        try data.write(to: file, options: .atomic)
      case let .file(source):
        try FileManager.default.copyItem(at: source, to: file)
      }
      return (directory, file)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  nonisolated private static func safeFilename(name: String, mimeType: String) -> String {
    var candidate = (name as NSString).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    candidate = candidate.unicodeScalars.map { scalar in
      if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" {
        return "_"
      }
      return String(scalar)
    }.joined()

    if candidate.isEmpty || candidate == "." || candidate == ".." {
      candidate = "Attachment"
    }

    if (candidate as NSString).pathExtension.isEmpty,
      let inferredExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension
    {
      candidate += ".\(inferredExtension)"
    }

    let pathExtension = String((candidate as NSString).pathExtension.prefix(32))
    guard !pathExtension.isEmpty else { return String(candidate.prefix(180)) }
    let stem = (candidate as NSString).deletingPathExtension
    let stemLimit = max(1, 179 - pathExtension.count)
    return "\(stem.prefix(stemLimit)).\(pathExtension)"
  }
}

private enum QuickLookError: LocalizedError {
  case attachmentUnavailable

  var errorDescription: String? {
    switch self {
    case .attachmentUnavailable:
      "The attachment is no longer available."
    }
  }
}
