import CodevisorClient
import Foundation
import UniformTypeIdentifiers

nonisolated struct DragNaming: Equatable {
  let type: UTType
  let suggestedName: String

  init(_ entry: ServerFileEntry) {
    self.init(name: entry.name, isDirectory: entry.isDirectory)
  }

  init(name: String, isDirectory: Bool) {
    guard !isDirectory else {
      self.init(type: .folder, suggestedName: name)
      return
    }
    let pathExtension = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    guard let type = UTType(filenameExtension: pathExtension), type.preferredFilenameExtension == pathExtension,
      !pathExtension.isEmpty, !stem.isEmpty
    else {
      self.init(type: .data, suggestedName: name)
      return
    }
    self.init(type: type, suggestedName: stem)
  }

  private init(type: UTType, suggestedName: String) {
    self.type = type
    self.suggestedName = suggestedName
  }
}
