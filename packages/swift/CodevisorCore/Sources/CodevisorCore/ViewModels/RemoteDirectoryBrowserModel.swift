import Foundation
import Observation

@MainActor
@Observable
public final class RemoteDirectoryBrowserModel {
  public typealias Lister = @Sendable (_ path: String, _ showHidden: Bool) async throws -> ServerFsListing

  public struct Column: Identifiable, Equatable, Sendable {
    public let path: String
    public var listing: ServerFsListing?
    public var errorMessage: String?
    public var selectedEntryPath: String?
    public var isLoading = false

    public var id: String { path }

    public init(path: String) {
      self.path = path
    }
  }

  public private(set) var columns: [Column] = []
  public private(set) var showHidden = false
  public private(set) var goToError: String?

  private let list: Lister
  private let machineName: String
  private var cache: [String: ServerFsListing] = [:]
  private var generation = 0
  private var cacheGeneration = 0

  public init(machineName: String, list: @escaping Lister) {
    self.machineName = machineName
    self.list = list
  }

  public var chosenPath: String? {
    for column in columns.reversed() {
      if let selected = column.selectedEntryPath { return selected }
    }
    return columns.first?.listing?.path
  }

  public var canGoUp: Bool {
    columns.first?.listing?.parent != nil
  }

  public func open(_ path: String) async {
    generation += 1
    let requestGeneration = generation
    var column = Column(path: path)
    column.isLoading = true
    columns = [column]
    goToError = nil
    do {
      let listing = try await fetch(path: path, showHidden: showHidden)
      guard generation == requestGeneration else { return }
      columns = [resolvedColumn(for: listing)]
    } catch {
      guard generation == requestGeneration else { return }
      columns[0].isLoading = false
      columns[0].errorMessage = Self.guidance(
        code: serverErrorCode(error),
        fallback: serverErrorMessage(error),
        machineName: machineName
      )
    }
  }

  public func select(_ entryPath: String, inColumn columnPath: String) async {
    guard let index = columns.firstIndex(where: { $0.path == columnPath }) else { return }
    if columns[index].selectedEntryPath == entryPath,
      columns.count > index + 1,
      columns[index + 1].path == entryPath
    {
      return
    }
    generation += 1
    let requestGeneration = generation
    columns[index].selectedEntryPath = entryPath
    columns.removeSubrange((index + 1)...)
    var child = Column(path: entryPath)
    child.isLoading = true
    columns.append(child)
    do {
      let listing = try await fetch(path: entryPath, showHidden: showHidden)
      guard generation == requestGeneration else { return }
      columns[columns.count - 1] = resolvedColumn(for: listing)
    } catch {
      guard generation == requestGeneration else { return }
      columns[columns.count - 1].isLoading = false
      columns[columns.count - 1].errorMessage = Self.guidance(
        code: serverErrorCode(error),
        fallback: serverErrorMessage(error),
        machineName: machineName
      )
    }
  }

  public func prependParent() async {
    guard let first = columns.first, let parent = first.listing?.parent else { return }
    generation += 1
    let requestGeneration = generation
    var column = Column(path: parent)
    column.isLoading = true
    column.selectedEntryPath = first.listing?.path
    columns.insert(column, at: 0)
    do {
      let listing = try await fetch(path: parent, showHidden: showHidden)
      guard generation == requestGeneration else { return }
      var resolved = resolvedColumn(for: listing)
      resolved.selectedEntryPath = columns[0].selectedEntryPath
      columns[0] = resolved
    } catch {
      guard generation == requestGeneration else { return }
      columns.removeFirst()
    }
  }

  @discardableResult
  public func goToPath(_ raw: String) async -> Bool {
    generation += 1
    let requestGeneration = generation
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      goToError = Self.guidance(code: "invalid_path", fallback: "", machineName: machineName)
      return false
    }
    do {
      let listing = try await fetch(path: trimmed, showHidden: showHidden)
      guard generation == requestGeneration else { return false }
      columns = [resolvedColumn(for: listing)]
      goToError = nil
      return true
    } catch {
      guard generation == requestGeneration else { return false }
      goToError = Self.guidance(
        code: serverErrorCode(error),
        fallback: serverErrorMessage(error),
        machineName: machineName
      )
      return false
    }
  }

  public func clearGoToError() {
    goToError = nil
  }

  public func revealCreatedFolder(_ path: String, parentPath: String) async {
    invalidateCachedListing(for: parentPath)
    invalidateCachedListing(for: path)
    guard let parentIndex = columns.firstIndex(where: { $0.path == parentPath }) else {
      await open(path)
      return
    }

    generation += 1
    let requestGeneration = generation
    columns[parentIndex].selectedEntryPath = path
    columns.removeSubrange((parentIndex + 1)...)
    var child = Column(path: path)
    child.isLoading = true
    columns.append(child)

    do {
      let parentListing = try await fetch(path: parentPath, showHidden: showHidden)
      guard generation == requestGeneration else { return }
      var refreshedParent = resolvedColumn(for: parentListing)
      refreshedParent.selectedEntryPath = path
      columns[parentIndex] = refreshedParent
    } catch {
      guard generation == requestGeneration else { return }
    }

    do {
      let childListing = try await fetch(path: path, showHidden: showHidden)
      guard generation == requestGeneration else { return }
      columns[parentIndex + 1] = resolvedColumn(for: childListing)
    } catch {
      guard generation == requestGeneration else { return }
      columns[parentIndex + 1].isLoading = false
      columns[parentIndex + 1].errorMessage = Self.guidance(
        code: serverErrorCode(error),
        fallback: serverErrorMessage(error),
        machineName: machineName
      )
    }
  }

  public func setShowHidden(_ value: Bool) async {
    guard value != showHidden else { return }
    showHidden = value
    generation += 1
    let requestGeneration = generation
    let paths = columns.map(\.path)
    let selections = columns.map(\.selectedEntryPath)
    var reloaded: [Column] = []
    for (index, path) in paths.enumerated() {
      do {
        let listing = try await fetch(path: path, showHidden: value)
        guard generation == requestGeneration else { return }
        var column = resolvedColumn(for: listing)
        if let selected = selections[index],
          listing.entries.contains(where: { $0.path == selected })
        {
          column.selectedEntryPath = selected
          reloaded.append(column)
        } else {
          reloaded.append(column)
          break
        }
      } catch {
        guard generation == requestGeneration else { return }
        break
      }
    }
    if !reloaded.isEmpty {
      columns = reloaded
    }
  }

  private func resolvedColumn(for listing: ServerFsListing) -> Column {
    var column = Column(path: listing.path)
    column.listing = listing
    return column
  }

  private func fetch(path: String, showHidden: Bool) async throws -> ServerFsListing {
    let key = "\(showHidden ? "h" : "v"):\(path)"
    if let cached = cache[key] { return cached }
    let requestGeneration = generation
    let requestCacheGeneration = cacheGeneration
    let listing = try await list(path, showHidden)
    guard generation == requestGeneration, cacheGeneration == requestCacheGeneration else { return listing }
    cache[key] = listing
    cache["\(showHidden ? "h" : "v"):\(listing.path)"] = listing
    return listing
  }

  private func invalidateCachedListing(for path: String) {
    cacheGeneration += 1
    cache.removeValue(forKey: "v:\(path)")
    cache.removeValue(forKey: "h:\(path)")
  }

  public static func guidance(code: String?, fallback: String, machineName: String) -> String {
    switch code {
    case "not_found":
      return "That folder doesn't exist on \(machineName). Check the path and try again."
    case "permission_denied":
      return "Codevisor on \(machineName) isn't allowed to read that folder. "
        + "Pick another folder, or adjust its permissions on the machine."
    case "not_a_directory":
      return "That path is a file, not a folder."
    case "invalid_path":
      return "Enter an absolute path (starting with /), or ~ for the home folder."
    default:
      return fallback
    }
  }
}
