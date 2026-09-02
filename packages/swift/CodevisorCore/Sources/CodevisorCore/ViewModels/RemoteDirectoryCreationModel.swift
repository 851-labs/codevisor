import Foundation
import Observation

/// Creates one child folder for the remote project browsers. Both native
/// apps use this model so name validation, progress, and actionable failures
/// stay identical across platforms.
@MainActor
@Observable
public final class RemoteDirectoryCreationModel {
  public typealias Creator = @Sendable (_ path: String) async throws -> String

  public private(set) var isCreating = false
  public private(set) var errorMessage: String?

  private let machineName: String
  private let create: Creator

  public init(machineName: String, create: @escaping Creator) {
    self.machineName = machineName
    self.create = create
  }

  /// Returns a validation message for a single folder name, or nil when it
  /// can be submitted. Paths are deliberately rejected: New Folder creates
  /// exactly one child of the directory visible in the picker.
  public static func validationMessage(
    for rawName: String,
    existingNames: Set<String> = []
  ) -> String? {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty {
      return "Enter a folder name."
    }
    if name == "." || name == ".." {
      return "Enter a folder name other than . or ..."
    }
    if name.contains("/") || name.unicodeScalars.contains(where: { $0.value == 0 }) {
      return "The folder name contains an invalid character."
    }
    if existingNames.contains(name) {
      return "A folder named “\(name)” already exists here."
    }
    return nil
  }

  public func clearError() {
    errorMessage = nil
  }

  /// Creates a child of `parentPath` and returns the server-resolved path.
  /// A nil result leaves `errorMessage` ready for inline presentation.
  @discardableResult
  public func createFolder(
    named rawName: String,
    in parentPath: String,
    existingNames: Set<String> = []
  ) async -> String? {
    guard !isCreating else { return nil }
    if let validation = Self.validationMessage(for: rawName, existingNames: existingNames) {
      errorMessage = validation
      return nil
    }

    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = (parentPath as NSString).appendingPathComponent(name)
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }

    do {
      return try await create(path)
    } catch {
      errorMessage = Self.guidance(
        code: serverErrorCode(error),
        fallback: serverErrorMessage(error),
        machineName: machineName
      )
      return nil
    }
  }

  public static func guidance(code: String?, fallback: String, machineName: String) -> String {
    switch code {
    case "permission_denied":
      return "Codevisor on \(machineName) isn't allowed to create a folder here. "
        + "Choose another location or adjust its permissions."
    case "not_a_directory":
      return "A file is in the way. Choose a different folder name or location."
    case "already_exists":
      return "A folder with that name already exists here."
    case "not_found":
      return "This location no longer exists on \(machineName). Go back and choose another folder."
    case "invalid_path":
      return "This folder location isn't valid. Go back and choose another folder."
    default:
      return fallback
    }
  }
}
